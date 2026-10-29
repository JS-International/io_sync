require_relative "lib/io_sync/version"

Gem::Specification.new do |spec|
  spec.name        = "io_sync"
  spec.version     = IoSync::VERSION
  spec.authors     = [ "Richard Dickson" ]
  spec.email       = [ "richard@dc5.net" ]
  spec.homepage    = "https://github.com/dc5/io_sync"
  spec.summary     = "One-way sync of Intelliflo Office clients into HighLevel and Zoom Phone."
  spec.description = "Reads Intelliflo (master), compares with live HighLevel contacts and Zoom external contacts, " \
                     "and pushes differences. Stores only link keys locally. Plan-only by default."
  spec.license     = "MIT"
  spec.metadata["allowed_push_host"] = "https://rubygems.example.invalid"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 8.0"
  spec.add_dependency "faraday", "~> 2.9"
  spec.add_dependency "faraday-retry", "~> 2.2"
  spec.add_dependency "phonelib", ">= 0.9"
  spec.add_dependency "concurrent-ruby", ">= 1.2"
  spec.add_dependency "csv"
  spec.add_dependency "base64"
end
