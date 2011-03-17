require 'bundler'
Bundler.require

desc "Create the message secret"
task :secret do
  path = File.join(File.dirname(__FILE__), "config", "secret.yml")
  secret = ActiveSupport::SecureRandom.hex(40)
  File.open(path, 'w') do |f|
    f.write <<-"EOF"
---
secret: #{secret}
    EOF
  end
end