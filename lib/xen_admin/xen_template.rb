require 'active_support/core_ext/numeric'

require 'xen_admin/verifier'
require 'xen_admin/xen_api'

module XenAdmin
  module XenTemplate
    module Helpers
      class Template
#        include XenAdmin::Verifier::Helpers
#        include XenAdmin::XenAPI::Helpers
#        include Sinatra::Helpers
#        include Rack::Utils
      
        attr_reader :request
      
        def initialize(template_name, chef_node, request)
          @node = chef_node
          @request = request
        
          raise ArgumentError unless template_name =~ /^[\w-]+$/
          raw_tmpl = File.read(File.join(settings.root, 'templates', "#{template_name}.yml"))
          @tmpl = YAML.load(ERB.new(raw_tmpl).result(binding))
        
          # check require values
          raise ArgumentError.new("Xen Template was not defined") if self.xen_template_label.empty?
          raise ArgumentError.new("Flavor was not defined") if self.flavor.empty?
        end
      
        def xen_template_label
          @tmpl['template'].to_s
        end
      
        def flavor
          @tmpl['flavor'].downcase
        end
      
        def boot_params(seed_url)
          case flavor
          when 'debian', 'ubuntu'
            [
              "auto-install/enable=true",
              "debian-installer/locale=" + default(:locale, 'en_US'),
              "debian-installer/country=" + default(:country, 'USA'),
              "netcfg/get_hostname=" + default(:hostname, ActiveSupport::SecureRandom.hex(5)),
              "netcfg/get_domain=" + default(:domain, 'localdomain'),
              "preseed/url=" + seed_url
            ].join (' ')
          else
            raise "Unknown Flavor #{@tmpl['flavor']}"
          end
        end
      
        def repository
          @tmpl['repository'] ||
          case flavor
          when 'debian', 'ubuntu'
            @node[flavor] && @node[flavor]['archive_url']
          end
        end
      
        def memory
          {
            :min => @tmpl['memory'] && @tmpl['memory']['min'] || 256.megabytes,
            :max => @tmpl['memory'] && (@tmpl['memory']['max'] || @tmpl['memory']['min']) || 256.megabytes
          }
        end
      
        def storage
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
      
        def network
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
                raise "Unknown network" unless network_ref.is_a? String

                interfaces[id.to_s] = {
                  :network => network_ref,
                  :mac => interface[:mac] || generate_mac,
                  :mtu => network['mtu'].to_s || '1500'
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
      
      private
        def default(key, default)
          if key.is_a? Hash
            tmpl_key = key[:tmpl].to_s
            node_key = key[:node].to_s
          else
            tmpl_key = node_key = key.to_s
          end
          (@node['bootstrap'] && @node['bootstrap'][node_key]) ||
            @node[node_key] ||
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
            raise "Can't find default_sr for XenServer pool." if sr_ref.nil || sr_ref.empty?
            xen.SR.get_uuid(sr_ref)
          end
        end
      end
    end

    def self.registered(app)
      app.helpers XenTemplate::Helpers
    end
  end
end