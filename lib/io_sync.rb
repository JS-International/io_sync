require "faraday"
require "faraday/retry"
require "phonelib"
require "concurrent"
require "json"
require "base64"
require "set"
require "digest"

require "io_sync/version"
require "io_sync/errors"
require "io_sync/configuration"
require "io_sync/http/write_guard"
require "io_sync/http/rate_limiter"
require "io_sync/http/raise_errors"
require "io_sync/http/connection"
require "io_sync/clients/intelliflo"
require "io_sync/clients/high_level"
require "io_sync/clients/zoom"
require "io_sync/phone"
require "io_sync/io_record"
require "io_sync/hl_mapper"
require "io_sync/zoom_mapper"
require "io_sync/number_registry"
require "io_sync/snapshot"
require "io_sync/snapshot_loader"
require "io_sync/link_store"
require "io_sync/plan"
require "io_sync/planners/links"
require "io_sync/planners/high_level"
require "io_sync/planners/zoom"
require "io_sync/applier"
require "io_sync/report"
require "io_sync/reconcile"
require "io_sync/engine" if defined?(Rails::Engine)

# IoSync reads Intelliflo Office (the master), compares with the live HighLevel
# and Zoom Phone records, and pushes differences. The only local state is the
# io_sync_links table. Runs are plan-only unless both the mode and the
# writes_enabled kill switch say otherwise.
module IoSync
  class << self
    def config
      @config ||= Configuration.new
    end

    # validate: false defers the completeness check to the start of each run,
    # so a missing credential fails the sync job, not the host app's boot.
    def configure(validate: true)
      yield config
      config.validate! if validate
      config
    end

    def reset_config!
      @config = nil
    end

    # Convenience entry point: IoSync.reconcile(mode: :plan) => Report
    def reconcile(mode: :plan, approved: nil, scope: nil, snapshot: nil, refresh_remote: false, config: self.config)
      Reconcile.new(mode: mode, approved: approved, scope: scope, snapshot: snapshot, refresh_remote: refresh_remote, config: config).call
    end
  end
end
