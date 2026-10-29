ENV["RAILS_ENV"] ||= "test"
require "spec_helper"
require_relative "dummy/config/environment"
require "rspec/rails"

ActiveRecord::Migration.verbose = false
ActiveRecord::MigrationContext.new(IoSync::Engine.root.join("db/migrate").to_s).migrate

Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |f| require f }

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.include ActiveJob::TestHelper, type: :job
  config.before(:each) do
    IoSync.reset_config!
    ActionMailer::Base.deliveries.clear
  end
end
