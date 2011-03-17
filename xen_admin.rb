require 'bundler'
Bundler.require

$: << File.join(File.dirname(__FILE__), 'lib')
require 'xenapi/xenapi'

require 'active_support/core_ext/numeric'

class XenAdmin < Sinatra::Base
  register Sinatra::ConfigFile

  configure do |c|
    set :app_file, __FILE__

    config_file "config/settings.yml"
    config_file "config/#{c.environment}.settings.yml"

    config_file "config/secret.yml"
    raise "I need a signing secret. Run `rake secret` to create one." unless settings.respond_to? :secret
    
    # create absolute path to chef key file
    settings.chef['config'] = File.expand_path(settings.chef['config'], root) if settings.chef['config']

    # configure spice for accessing the chef server
    Spice.setup do |s|
      %w(host port scheme client_name key_file).each do |config|
        s.send("#{config}=", settings.chef[config]) if settings.chef[config]
      end
    end
    Spice.connect!
  end
  
  helpers do
    include Rack::Utils
    
    def xenapi(&block)
      session = XenAPI::Session.new(settings.xen['host'])
      begin
        session.login_with_password(settings.xen['username'], settings.xen['password'])
        ret = yield session
      ensure
        session.logout
      end
      ret
    end
    
    def verifier
      @verifier ||= ActiveSupport::MessageVerifier.new(settings.secret)
    end
    
    def sign(data)
      verifier.generate({
        :node_name => data,
        :generated_at => Time.now
      })
    end
    
    def verify(signed_data)
      data = verifier.verify(signed_data)
      halt 403, "Stale data detected" if Time.now - data[:generated_at] > settings.session_lifetime.to_i
    end
    
    def template(name, node)
      raise ArgumentError unless name =~ /^[\w-]+$/

      @template ||= {}
      @template[name] ||= begin
        raw_tmpl = File.read(File.join(File.dirname(__FILE__), 'templates', "#{name}.yml"))
        YAML.load(ERB.new(raw_tmpl).result(binding))
      end
    end
    
    def generate_mac
      "00:15:3e:" + (1..3).map{"%02x" % (rand*0xff)}.join(':')
    end
  end
  
  get '/bootstrap' do
    # TODO: This needs to be authenticated
    # This currently requires https://github.com/danryan/spice/pull/2
    available_nodes = JSON.parse(Spice::Search.node :q => "!cpu:[* TO *]")
    
    available_nodes['rows'].inject({}) do |result, node|
      result[node['name']] = url("/bootstrap/#{escape(node['name'])}")
      result
    end.to_json
  end
  
  get "/bootstrap/:node_name/:template" do
    # TODO: This needs to be authenticated
    # TODO: This should be a POST
    node = JSON.parse(Spice::Node[params[:node_name]])

    b = node['bootstrap'] || {}
    t = template(params[:template], node)
    
    vars = {
      :template_name => t['template'].to_s,
      :boot_params => [
        "auto-install/enable=true",
        "debian-installer/locale=" + (b['locale'] || t['locale'] || 'en_US'),
        "debian-installer/country=" + (b['country'] || t['country'] || 'USA'),
        "netcfg/get_hostname=" + (node['hostname'] || t['hostname'] || ActiveSupport::SecureRandom.hex(5)),
        "netcfg/get_domain=" + (node['domain'] || t['domain'] || 'localdomain'),
        "preseed/url=" + url("/bootstrap/#{escape(sign node['name'])}/seed")
      ],
      :repository => t['repository'] || node['debian'] && node['debian']['archive_url'],
      :memory => {
        :min => t['memory'] && t['memory']['min'] || 256.megabytes,
        :max => t['memory'] && (t['memory']['max'] || t['memory']['min']) || 256.megabytes
      },
      :storage => {
        # TODO: use bootstrap values
        :default_sr => t['storage'] && t['storage']['default_sr'],
        :disks => begin
          if t['storage'] && t['storage']['disks']
            t['storage']['disks'].inject({}) do |disks, (id, disk)|
              disks[id.to_s] = {
                :size => disk['size'] || 8.gigabytes,
                :bootable => disk['bootable'].to_s == 'true',
                :sr => disk['sr'] || t['storage']['default_sr']
              }
              disks
            end
          else
            {'0' => {:size => 8.gigabytes, :bootable => true}}
          end
        end
      },
      :network => begin
        # TODO: use bootstrap values
        if t[:network]
          xenapi do |xen|
            t[:network].inject({}) do |networks, (id, network)|
              networks[id.to_s] = {
                :network => xen.network.get_by_uuid(network['network']),
                :mac => network['mac'] || generate_mac,
                :mtu => network['mtu'].to_s || '1500'
              }
            end
          end
        else
          network_refs = xenapi do |xen|
            xen.network.get_all.select do |network_ref|
              network = xen.network.get_record(network_ref)
              !(network['other_config']['automatic'] == 'false' || network['PIFs'].empty?)
            end
          end
          interfaces = {}
          network_refs.each_with_index do |ref, i|
            interfaces[(i+1).to_s] = {
              :network => ref,
              :mac => generate_mac,
              :mtu => '1500'
            }
          end
          interfaces
        end
      end
      
    }

    ## Setting up the new VM
    xenapi do |xen|
      # logger.debug("Cloning #{vars[:template_name]}")
      
      templates = xen.VM.get_by_name_label(vars[:template_name])

      # check target configuration
      halt 403, "XenServer Template not found" unless templates.size == 1
      halt 403, "Source repository not found." unless vars[:repository]
      
      ## Cloning the VM
      vm_ref = xen.VM.clone(templates[0], params[:node_name])
      vm = xen.VM.get_record(vm_ref)
      
      ## Configure the new VM
      # Install source
      xen.VM.add_to_other_config(vm_ref, "install-repository", vars[:repository])
      
      # Boot parameters
      xen.VM.set_PV_args(vm_ref, vars[:boot_params].join(" ") + " " + vm['PV_args'])
      
      # Memory
      xen.VM.set_memory_dynamic_min(vm_ref, vars[:memory][:min].to_s)
      xen.VM.set_memory_dynamic_max(vm_ref, vars[:memory][:max].to_s)
      
      ## Provision the storage
      # find the default SR
      if vars[:storage][:default_sr]
        # check if SR is valid
        halt 403, "Configured default_sr is invalid" if xen.SR.get_by_uuid(vars[:storage][:default_sr]).blank?
        default_sr = vars[:storage][:default_sr]
      elsif vars[:storage][:disks].first{ |id, disk| !disk[:sr] }
        pool_refs = xen.pool.get_all
        if pool_refs.size == 1
          pool_ref = pool_refs[0]
          sr_ref = xen.pool.get_record(pool_ref)['default_SR']
          default_sr = xen.SR.get_uuid(sr_ref)
        end
        halt 403, "Can't find default_sr for XenServer pool." unless default_sr
      end

      # build the provision XML specification
      disks = vars[:storage][:disks].collect do |device, values|
        values = {:device => device, :sr => default_sr, :type => 'system'}.merge(values)
        values[:sr] ||= default_sr
        disk = values.collect{ |k, v| "#{k}=\"#{v}\""}.join(" ")
        "<disk #{disk} />"
      end
      provision = "<provision>#{disks.join}</provision>"

      # setting the provisioning XML to the VM
      xen.VM.remove_from_other_config(vm_ref, 'disks')
      xen.VM.add_to_other_config(vm_ref, 'disks', provision)
      
      # provision the disks
      xen.VM.provision(vm_ref)
      
      ## Create network interfaces
      vars[:network].each_pair do |id, device|
        vif_ref = xen.VIF.create(
          'device' => id.to_s,
          'network' => device[:network],
          'VM' => vm_ref,
          'MAC' => device[:mac],
          'MTU' => device[:mtu],
          'other_config' => {},
          'qos_algorithm_type' => '',
          'qos_algorithm_params' => {}
        )
      end
      
      ## Boot the VM
      xen.VM.start(vm_ref, false, false)
    end
    
    vars.to_json
  end

  get '/bootstrap/:id/seed' do
    data = verify(id)

    node = JSON.parse(Spice::Node[data[:node_name]])
    node.to_json
  end
  
  get '/' do
    redirect to("/bootstrap")
  end
end