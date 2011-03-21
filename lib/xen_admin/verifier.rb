module XenAdmin
  module Verifier
    module Helpers
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
    end
    
    def self.registered(app)
      app.helpers Verifier::Helpers
      
      app.configure do |c|
        config_file "config/secret.yml"
        raise "I need a signing secret. Run `rake secret` to create one." unless settings.respond_to? :secret
      end
    end
    
  end
end