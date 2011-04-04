require 'xenapi/xenapi'

module XenAdmin
  module Helpers
    module XenAPI
      module Helpers
        def xenapi(options={}, &block)
          session = ::XenAPI::Session.new(settings.xen['host'])
          begin
            session.login_with_password(settings.xen['username'], settings.xen['password'])
            @session_id = session.session_id
            ret = yield session
          ensure
            session.logout unless options[:keep_session]
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