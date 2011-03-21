require 'xenapi/xenapi'
require 'sinatra/base'

module XenAdmin
  module XenAPI
    module Helpers
      def xenapi(&block)
        require 'pp'
        puts "----------------"
        pp settings
        

        session = ::XenAPI::Session.new(options.xen['host'])
        begin
          session.login_with_password(options.xen['username'], options.xen['password'])
          ret = yield session
        ensure
          session.logout
        end
        ret
      end
    end
    
    def self.registered(app)
      app.helpers XenAPI::Helpers
    end
  end
end