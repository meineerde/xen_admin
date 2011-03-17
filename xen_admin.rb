require 'bundler'
Bundler.require

$: << File.join(File.dirname(__FILE__), 'lib')
require 'xenapi/xenapi'

class XenAdmin < Sinatra::Base
  register Sinatra::ConfigFile

  configure do |c|
    set :app_file, __FILE__

    config_file "config/settings.yml"
    config_file "config/#{c.environment}.settings.yml"

    config_file "config/secret.yml"
    raise "I need a signing secret. Run `rake secret` to create one." unless settings.secret
    
    # create absolute path to chef key file
    settings.chef[config] = File.expand_path(settings.chef[config], File.dirname(__FILE__)) if settings.chef[config]

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
      data = @verifier.verify(signed_data)
      halt 403, "Stale data detected" if Time.now - data[:generated_at] > settings.session_lifetime.to_i
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
  
  get "/bootstrap/:node_name" do
    # TODO: This needs to be authenticated
    # TODO: This should be a POST
    node = JSON.parse(Spice::Node[params[:node_name]])
    
    vars = {:seed_url => url("/bootstrap/#{escape(sign node['name'])}/seed")}
    xenapi do |xen|
      # create the Virtual machine
      # start it and send it the seed url
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