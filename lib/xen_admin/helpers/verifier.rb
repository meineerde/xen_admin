module XenAdmin
  module Helpers
    module Verifier
      module Helpers
        def verifier
          @verifier ||= ActiveSupport::MessageVerifier.new(settings.secret, 'SHA256')
        end

        def sign(data)
          verifier.generate({
            :data => data,
            :generated_at => Time.now
          })
        end

        def verify(signed_data)
          data = verifier.verify(signed_data)
          halt 403, "Stale data detected" if Time.now - data[:generated_at] > settings.session_lifetime.to_i
          data[:data]
        end
      end

      def self.registered(app)
        app.configure do |c|
          c.config_file "config/secret.yml"
          raise "I need a signing secret. Run `rake secret` to create one." unless c.settings.respond_to? :secret
        end

        app.helpers Verifier::Helpers
      end
    end
  end
end