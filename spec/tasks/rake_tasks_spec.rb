require "rails_helper"
require "rake"

RSpec.describe "io_sync rake tasks" do
  it "registers each task once, so a run is never repeated" do
    Rails.application.load_tasks
    %w[io_sync:plan io_sync:apply io_sync:apply_all io_sync:snapshot io_sync:find io_sync:links:import].each do |name|
      expect(Rake::Task[name].actions.size).to eq(1), "#{name} has #{Rake::Task[name].actions.size} actions"
    end
  end
end
