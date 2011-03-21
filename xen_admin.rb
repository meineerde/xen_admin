require 'bundler'
Bundler.require

require 'active_support/core_ext/numeric'

$: << File.join(File.dirname(__FILE__), 'lib')
require 'xen_admin/verifier'
require 'xen_admin/xen_api'
require 'xen_admin/xen_template'


class XenAdmin::Application < Sinatra::Base
  register Sinatra::ConfigFile

  register XenAdmin::Verifier
  register XenAdmin::XenAPI
  register XenAdmin::XenTemplate

  configure do |c|
    set :app_file, __FILE__

    config_file "config/settings.yml"
    config_file "config/#{environment}.settings.yml"

    # configure spice for accessing the chef server
    spice = settings.chef
    spice['key_file'] = File.expand_path(spice['key_file'], root) if spice['key_file']
    spice['scheme'], spice['host'] = spice['host'].split("://")[0..1].collect(&:downcase)

    Spice.setup do |s|
      %w(host port scheme client_name key_file).each do |config|
        s.send("#{config}=", spice[config]) if spice[config]
      end
    end
    Spice.connect!
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
    
    tmpl = Template.new(params[:template], node, request)

    ## Setting up the new VM
    xenapi do |xen|
      # logger.debug("Cloning #{vars[:template_name]}")
      
      xen_template_refs = xen.VM.get_by_name_label(tmpl.xen_template_label)
      
      # check target configuration
      halt 403, "XenServer Template #{tmpl.xen_template_label} not found" unless xen_template_refs.size == 1
      
      ## Cloning the VM
      vm_ref = xen.VM.clone(xen_template_refs[0], params[:node_name])
      vm = xen.VM.get_record(vm_ref)
      
      ## Configure the new VM
      # Install source
      xen.VM.add_to_other_config(vm_ref, "install-repository", tmpl.repository)
      
      # Boot parameters
      seed_url = url("/bootstrap/#{escape(sign node['name'])}/seed")
      xen.VM.set_PV_args(vm_ref, tmpl.boot_params(seed_url) + " " + vm['PV_args'])
      
      # Memory
      xen.VM.set_memory_dynamic_min(vm_ref, tmpl.memory[:min].to_s)
      xen.VM.set_memory_dynamic_max(vm_ref, tmpl.memory[:max].to_s)
      
      ## Provision the storage
      # build the provision XML specification
      disks = tmpl.storage.collect do |device, values|
        values = {:device => device, :type => 'system'}.merge(values)
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
      tmpl.network.each_pair do |id, device|
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