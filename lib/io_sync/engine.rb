module IoSync
  class Engine < ::Rails::Engine
    isolate_namespace IoSync

    initializer "io_sync.migrations" do |app|
      unless app.root.to_s.match?(root.to_s)
        config.paths["db/migrate"].expanded.each { |p| app.config.paths["db/migrate"] << p }
      end
    end

    # lib/tasks/*.rake is loaded by Rails::Engine itself. Loading it again here
    # registered every task twice, so `rake io_sync:plan` read Intelliflo twice.
  end
end
