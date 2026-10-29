module IoSync
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def copy_initializer
        template "initializer.rb", "config/initializers/io_sync.rb"
      end

      def show_next_steps
        say <<~TEXT

          IoSync installed. Next:
            1. Fill in config/initializers/io_sync.rb and add credentials under io_sync: in rails credentials.
            2. bin/rails db:migrate   (creates io_sync_links)
            3. bin/rails io_sync:links:import[io_sync_links.csv]   (one-off, from the old app)
            4. bin/rails io_sync:plan  and review the emailed report. Nothing is written until
               writes_enabled is true AND a run is started in apply mode.
        TEXT
      end
    end
  end
end
