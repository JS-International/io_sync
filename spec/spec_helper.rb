require "webmock/rspec"
WebMock.disable_net_connect!

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.order = :random
  config.example_status_persistence_file_path = "tmp/rspec_status"
  config.disable_monkey_patching!
  config.before(:each) do
    allow(IoSync::Http).to receive(:retry_options).and_return(IoSync::Http::RETRY_OPTIONS.merge(max: 1, interval: 0, backoff_factor: 1)) if defined?(IoSync::Http)
  end
end
