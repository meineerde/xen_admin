require 'bundler'
Bundler.require

require 'active_support/core_ext/numeric'

$: << File.join(File.dirname(__FILE__), 'lib')
require 'xen_admin/helpers/verifier'
require 'xen_admin/helpers/xen_api'
require 'xen_admin/helpers/xen_template'


class XenAdmin::Application < Sinatra::Base
  register Sinatra::ConfigFile

  configure do |c|
    set :app_file, __FILE__
    set :views, 'templates'

    config_file "config/settings.yml"
    config_file "config/#{environment}.settings.yml"

    # configure spice for accessing the chef server
    # spice = settings.chef
    # spice['key_file'] = File.expand_path(spice['key_file'], root) if spice['key_file']
    # spice['scheme'], spice['host'] = spice['host'].split("://")[0..1].collect(&:downcase)
    #
    # Spice.setup do |s|
    #   %w(host port scheme client_name key_file).each do |config|
    #     s.send("#{config}=", spice[config]) if spice[config]
    #   end
    # end
    # Spice.connect!
  end

  helpers do
    def get_node(hostname)
      return {'hostname' => hostname}

      # Load the node data from chef
      # Fresh nodes may take some time until they get caught up by ther API.
      waited = 0
      node = JSON.parse(Spice::Node[hostname])
      while (node.empty? || node.include?('error')) && waited < 12 do
        sleep 2
        waited += 2
        node = JSON.parse(Spice::Node[hostname])
      end
      if node.empty? || node.include?('error')
        raise "Could not load node data for #{hostname}"
      else
        node
      end
    end

    def partial(page, options={})
      erb page, options.merge!(:layout => false)
    end

    def port_available?(port)
      # TODO: keep global list of recently used ports
      # with timeout > timeout of vncauthproxy

      {
        Socket::Constants::AF_INET => "0.0.0.0",
        Socket::Constants::AF_INET6 => "::"
      }.each do |proto, addr|
        begin
          socket = Socket.new(proto, Socket::Constants::SOCK_STREAM, 0)
          sockaddr = Socket.sockaddr_in(port, addr)
          socket.bind( sockaddr )
        rescue Errno::EADDRINUSE:
          return false
        ensure
          socket.close
        end
      end
      return true
    end
  end

  register XenAdmin::Helpers::Verifier
  register XenAdmin::Helpers::XenAPI
  register XenAdmin::Helpers::XenTemplate

  get '/bootstrap' do
    # TODO: This needs to be authenticated

    # find nodes that are not yet bootstrapped, i.e. they do not have any
    # CPU info available
    available_nodes = JSON.parse(Spice::Search.node :q => "!cpu:[* TO *]")

    available_nodes['rows'].inject({}) do |result, node|
      result[node['name']] = url("/bootstrap/#{escape(node['name'])}")
      result
    end.to_json
  end

  get %r{/bootstrap/([^/]+)/((?:[\w\/-]|\.(?!\.))+)} do |id, seed|
    data = verify(id)
    node = get_node(data[:name])
    init_template(data[:template], node)

    content_type "text/plain"
    erb :"#{data[:template]}/#{seed}", :locals => {:node => node}
  end

  get "/bootstrap/:node_name" do
    # TODO: This needs to be authenticated
    # TODO: This should be a POST

    init_template(params[:template], get_node(params[:node_name]))

    ## Setting up the new VM
    xenapi do |xen|
      # logger.debug("Cloning #{vars[:template_name]}")

      xen_template_refs = xen.VM.get_by_name_label(tmpl_xen_template_label)

      # check target configuration
      halt 403, "XenServer Template #{tmpl_xen_template_label} not found" unless xen_template_refs.size == 1

      # get the template data
      vm = xen.VM.get_record(xen_template_refs[0])

      mem = tmpl_memory
      vm.merge!({
        "name_label" => tmpl_vm_label,
        "name_description" => tmpl_vm_description,
        "PV_args" => "#{tmpl_boot_params} #{vm["PV_args"]}",

        "VCPUs_max" => tmpl_vcpus,
        "VCPUs_at_startup" => tmpl_vcpus,

        "memory_dynamic_max" => mem[:dynamic_max],
        "memory_dynamic_min" => mem[:dynamic_min],
        "memory_static_min" => mem[:min],
        "memory_static_max" => mem[:max],
      })

      # build the XML specification for storage provision
      disks = tmpl_storage.collect do |device, values|
        values = {:device => device, :type => 'system'}.merge(values)
        disk = values.collect{ |k, v| "#{k}=\"#{v}\""}.join(" ")
        "<disk #{disk} />"
      end
      provision = "<provision>#{disks.join}</provision>"

      vm["other_config"].merge!({
        "install-repository" => tmpl_repository,
        "auto_poweron" => tmpl_auto_poweron,
        "disks" => provision,
        "default_template" => "false"
      })

      ## now create the new VM
      vm_ref = xen.VM.create(vm)

      ## Create network interfaces
      tmpl_network.each_pair do |id, device|
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

      ## Actually provision the disks
      xen.VM.provision(vm_ref)

      ## Add the CD drive
      # Find the xs-tools.iso VDI
      tools_sr_ref = xen.SR.get_all.find do |sr_ref|
        xen.SR.get_other_config(sr_ref)['xenserver_tools_sr'] == "true"
      end
      xs_tools_ref = xen.SR.get_VDIs(tools_sr_ref).find do |vdi_ref|
        xen.VDI.get_sm_config(vdi_ref)['xs-tools'] == "true"
      end

      # create the CD drive with mounted xs-tools
      xen.VBD.create(
        'VM' => vm_ref,
        'VDI' => xs_tools_ref,
        'userdevice' => (disks.count).to_s,
        'bootable' => false,
        'mode' => 'RO',
        'type' => 'CD',
        'unpluggable' => false,
        'empty' => false,
        'other_config' => {},
        'qos_algorithm_type' => '',
        'qos_algorithm_params' => {}
      )

      ## Boot the VM
      xen.VM.start(vm_ref, false, false)
    end

    201 # Resource created
  end

  get "/vnc/:host" do
    xenapi(:keep_session => true) do |xen|
      if is_uuid(params[:host])
        xen.VM.get_by_uuid(params[:host])
      else
        vm_ref = xen.VM.get_by_name_label(params[:host])[0]
      end
      halt 404 unless vm_ref

      console_ref = xen.VM.get_consoles(vm_ref)[0]
      uri = URI.parse(xen.console.get_location(console_ref))

      # Now connect to vncauthproxy's socket and setup a new forward
      socket = UNIXSocket.new("/tmp/vncproxy.sock")

      # TODO: generate this from a range
      vnc_port = nil
      while vnc_port == nil
        port = rand(settings.vnc_proxy_port_range['to'].to_i - settings.vnc_proxy_port_range['from'].to_i)
        port += settings.vnc_proxy_port_range['from'].to_i

        vnc_port = port if port_available?(port)
      end

      # random password, 12 characters
      password = ActiveSupport::SecureRandom.base64(9)

      port = uri.scheme.downcase == "https" ? "#{uri.port}+" : uri.port
      socket_str = [
        vnc_port,
        uri.host,
        port,
        password,
        "#{uri.request_uri}&session_id=#{@session_id}"
      ].join(":")
      socket.puts(socket_str)
      halt(500, "Something went wrong") unless socket.read.start_with?("OK")

      {
        :host => request.host,
        :port => vnc_port,
        :password => password,
        :require_ssl => true
      }.to_json
    end
  end

  get '/' do
    redirect to("/bootstrap")
  end
end