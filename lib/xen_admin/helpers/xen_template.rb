require 'active_support/core_ext/numeric'

require 'xen_admin/helpers/verifier'
require 'xen_admin/helpers/xen_api'

module XenAdmin
  module Helpers
    module XenTemplate
      module Helpers

        def init_template(template_name, chef_node)
          @template_name = template_name
          @chef_node = chef_node

          raise ArgumentError unless template_name =~ /^[\w-]+$/
          raw_tmpl = File.read(File.join(settings.root, 'templates', "#{template_name}.yml"))
          @tmpl = YAML.load(ERB.new(raw_tmpl).result(binding))

          # check require values
          raise ArgumentError.new("Xen Template was not defined") if tmpl_xen_template_label.empty?
          raise ArgumentError.new("Flavor was not defined") if tmpl_flavor.empty?
        end

        def tmpl_xen_template_label
          @tmpl['template'].to_s
        end

        def tmpl_name
          @template_name
        end

        def tmpl_vm_label
          tmpl_default(:name)
        end

        def tmpl_vm_description
          tmpl_default(:description, "")
        end

        def tmpl_flavor
          @tmpl['flavor'].downcase
        end

        def tmpl_locale
          tmpl_default(:locale, 'en_US')
        end

        def tmpl_language
          tmpl_locale.split("_")[0]
        end

        def tmpl_country
          @tmpl['country'] || tmpl_locale.split("_")[1]
        end

        def tmpl_boot_params
          case tmpl_flavor
          when 'debian', 'ubuntu'
            bootstrap_data = {
              :name => @chef_node['name'],
              :template => tmpl_name
            }

            [
              "auto=true",
              "url=" + url("/bootstrap/#{escape(sign bootstrap_data)}/preseed.cfg"),
              "locale=" + tmpl_default(:locale, 'en_US'),
              "country=" + tmpl_default(:country, '"United States"'),
              "hostname=" + tmpl_default(:hostname, ActiveSupport::SecureRandom.hex(5)),
              "domain=" + tmpl_default(:domain, 'localdomain')
            ].join(' ')
          else
            raise "Unknown Flavor #{@tmpl['flavor']}"
          end
        end

        def tmpl_repository
          @tmpl['repository'] ||
          case tmpl_flavor
          when 'debian', 'ubuntu'
            @chef_node[flavor] && @chef_node[flavor]['archive_url']
          end
        end

        def tmpl_repository_proxy
          if @tmpl.include? 'repository_proxy'
            @tmpl['repository_proxy']
          else
            case tmpl_flavor
            when 'debian', 'ubuntu'
              proxies = JSON.parse(Spice::Search.node('recipes:apt\:\:cacher'))
              "http://#{proxies['rows'][0]['ipaddress']}:3142" if proxies['total'] > 0
            end
          end
        end

        def tmpl_memory
          {
            :min => @tmpl['memory'] && @tmpl['memory']['min'] || 256.megabytes,
            :max => @tmpl['memory'] && (@tmpl['memory']['max'] || @tmpl['memory']['min']) || 256.megabytes
          }
        end

        def tmpl_storage
          # TODO: use node values
          default_sr = @tmpl['storage'] && @tmpl['storage']['default_sr']

          if @tmpl['storage'] && @tmpl['storage']['disks']
            # template defines some disks
            disks = {}
            @tmpl['storage']['disks'].keys.sort.each_with_index do |key, id|
              disk = @tmpl['storage']['disks'][key]
              disks[id.to_s] = {
                :size => disk['size'] || 8.gigabytes,
                :bootable => disk['bootable'].to_s.downcase == "true",
                :sr => disk['sr'] || default_sr || xen_default_sr
              }
            end
          else
            # use a single 8 GB disk by default
            disks = {'0' => {:size => 8.gigabytes, :bootable => true}}
          end
          disks
        end

        def tmpl_network
          interfaces = {}

          if @tmpl['network']
            # Template has network interfaces specified
            xenapi do |xen|
              @tmpl['network'].keys.sort.each_with_index do |key, id|
                interface = @tmpl['network'][key]

                if interface['network'] =~ /^[[:xdigit:]]{8}-([[:xdigit:]]{4}-){3}[[:xdigit:]]{12}$/
                  network_ref = xen.network.get_by_uuid(interface['network'])
                else
                  network_ref = xen.network.get_by_name_label(interface['network'])
                end

                if network_ref.is_a?(Array) && network_ref.size == 1 && network_ref[0] != "OpaqueRef:NULL"
                  network_ref = network_ref[0]
                else
                  raise "Unknown network '#{interface['network']}' for interface #{id}"
                end

                interfaces[id.to_s] = {
                  :network => network_ref,
                  :mac => (interface['mac'] || generate_mac).to_s,
                  :mtu => (interface['mtu'] || 1500).to_s
                }
              end
            end
          else
            # No network interfaces specified. Create an interface for each
            # available auto-network.

            # find networks to use
            network_refs = xenapi do |xen|
              xen.network.get_all.reject do |network_ref|
                pifs = xen.network.get_PIFs(network_ref)
                network['other_config']['automatic'] == 'false' || pifs.empty?
              end
            end

            # create interface specifications
            network_refs.each_with_index do |ref, i|
              interfaces[(i+1).to_s] = {
                :network => ref,
                :mac => generate_mac,
                :mtu => '1500'
              }
            end
          end
          interfaces
        end

        def tmpl_install_interface
          if @tmpl['install_interface'].is_a? Hash
            interface = @tmpl['install_interface']
            result = {
              :interface => interface['interface'], # might be nil if not set
              :ip_config => interface['ip_config'] == 'static' ? 'static' : 'dhcp'
            }
            if result[:ip_config] == 'static'
              result[:static] = {
                :ipaddress => interface['static']['ipaddress'],
                :netmask => interface['static']['netmask'],
                :gateway => interface['static']['gateway'],
                :nameservers => interface['static']['nameservers']
              }
            end
          else
            result = {
              :interface => nil,
              :ip_config => 'dhcp'
            }
          end
          result
        end

      private
        def tmpl_default(key, default=nil)
          if key.is_a? Hash
            tmpl_key = key[:tmpl].to_s
            node_key = key[:node].to_s
          else
            tmpl_key = node_key = key.to_s
          end
          (@chef_node['bootstrap'] && @chef_node['bootstrap'][node_key]) ||
            @chef_node[node_key] ||
            @tmpl[tmpl_key] ||
            default
        end

        def generate_mac
          "00:15:3e:" + (1..3).map{"%02x" % (rand*0xff)}.join(':')
        end

        def xen_default_sr
          # find the default_sr from xen
          xenapi do |xen|
            pool_refs = xen.pool.get_all
            raise "Multiple Pools found for Xen server" unless pool_refs.size == 1

            sr_ref = xen.pool.get_default_SR(pool_refs[0])
            raise "Can't find default_sr for XenServer pool." if sr_ref.nil? || sr_ref == "OpaqueRef:NULL"
            xen.SR.get_uuid(sr_ref)
          end
        end
      end

      def self.registered(app)
        app.helpers XenTemplate::Helpers
      end
    end
  end
end