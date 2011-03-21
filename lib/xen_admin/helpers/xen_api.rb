require 'xenapi/xenapi'

module XenAdmin
  module Helpers
    module XenAPI
      module Helpers
        def xenapi(&block)
          session = ::XenAPI::Session.new(settings.xen['host'])
          begin
            session.login_with_password(settings.xen['username'], settings.xen['password'])
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
end