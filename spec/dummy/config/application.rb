require_relative "boot"
require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "action_mailer/railtie"
require "action_view/railtie"
require "io_sync"
require "io_sync/engine"

module Dummy
  class Application < Rails::Application
    config.load_defaults 8.0
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.active_job.queue_adapter = :test
    config.action_mailer.delivery_method = :test
    config.action_mailer.default_url_options = { host: "example.test" }
    config.logger = Logger.new(File::NULL)
    config.active_record.dump_schema_after_migration = false
  end
end
