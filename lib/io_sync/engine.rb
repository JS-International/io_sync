module IoSync
  class Engine < ::Rails::Engine
    isolate_namespace IoSync

    initializer "io_sync.migrations" do |app|
      unless app.root.to_s.match?(root.to_s)
        config.paths["db/migrate"].expanded.each { |p| app.config.paths["db/migrate"] << p }
      end
    end

    rake_tasks do
      load File.expand_path("../tasks/io_sync.rake", __dir__)
    end
  end
end
