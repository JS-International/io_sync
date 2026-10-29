require "securerandom"
require "time"

module IoSync
  # One run: load → plan → gate → (apply) → report. Plan mode never builds a
  # writable client, so nothing can be written even by mistake.
  #
  # snapshot: a JSON file path. In plan mode, if the file exists the run plans
  # against it with no API calls; otherwise it reads live and saves it there.
  # With refresh_remote: true a plan run also re-reads HL and Zoom live, so a
  # plan reviewed later in the day matches what apply will see.
  # In apply mode the file must exist and be younger than
  # config.snapshot_max_age_hours; only its Intelliflo side is used, HL and
  # Zoom are re-read live. Links always come from the link store.
  class Reconcile
    attr_reader :config, :mode

    def initialize(mode: :plan, approved: nil, scope: nil, snapshot: nil, refresh_remote: false, config: IoSync.config,
                   intelliflo: nil, high_level: nil, zoom: nil, link_store: nil, mailer: :default, clock: Time)
      @mode = mode.to_sym
      raise ArgumentError, "mode must be :plan or :apply" unless %i[plan apply].include?(@mode)
      @approved = approved
      @snapshot_path = snapshot
      @refresh_remote = refresh_remote
      @scope = scope
      @config = config
      @intelliflo = intelliflo
      @high_level = high_level
      @zoom = zoom
      @link_store = link_store
      @mailer = mailer
      @clock = clock
    end

    def call
      config.validate!
      report = Report.new(run_id: @clock.now.strftime("%Y%m%d-%H%M%S") + "-" + SecureRandom.hex(2), mode: mode,
                          started_at: @clock.now, writes_enabled: config.writes_enabled, approved_from: @approved&.run_id)
      if mode == :apply && !config.writes_enabled
        raise WriteDisabled, "apply requested but IoSync.config.writes_enabled is false"
      end
      check_snapshot_for_apply! if mode == :apply && @snapshot_path

      begin
        snapshot = load_snapshot
        plan = Plan.new
        links = Planners::Links.new(snapshot, config: config, plan: plan).call
        Planners::HighLevel.new(snapshot, config: config, plan: plan, links: links, time: @clock.now).call
        Planners::Zoom.new(snapshot, config: config, plan: plan, links: links).call
        report.load_plan(plan, snapshot)

        if mode == :apply
          Applier.new(plan, config: config, high_level: high_level(writable: true), zoom: zoom(writable: true),
                      link_store: link_store, approved_digests: @approved&.digests).call
          report.status = :applied
        else
          report.status = :planned
        end
      rescue Aborted, RateLimited => e
        report.status = :aborted
        report.error = e.message
      ensure
        report.finished_at = @clock.now
        deliver(report)
      end
      report
    end

    private

    def load_snapshot
      loader = SnapshotLoader.new(config: config, intelliflo: intelliflo, high_level: high_level(writable: false),
                                  zoom: zoom(writable: false), link_store: link_store, scope: @scope)
      if @snapshot_path && File.exist?(@snapshot_path)
        snapshot = Snapshot.load_file(@snapshot_path)
        snapshot.links = link_store.all.to_h { |l| [ l.io_id, l ] }
        snapshot.stats.merge!(links: snapshot.links.size, snapshot_from: @snapshot_path.to_s)
        loader.refresh_remote(snapshot) if mode == :apply || @refresh_remote
        return snapshot
      end
      snapshot = loader.load
      snapshot.save(@snapshot_path) if @snapshot_path
      snapshot
    end

    # Never let an apply fall through to a fresh IO read, or act on old IO data.
    def check_snapshot_for_apply!
      raise Error, "snapshot #{@snapshot_path} does not exist; apply will not read Intelliflo in its place" unless File.exist?(@snapshot_path)
      saved_at = Time.parse(JSON.parse(File.read(@snapshot_path)).fetch("saved_at"))
      age_hours = (@clock.now - saved_at) / 3600.0
      return if age_hours <= config.snapshot_max_age_hours
      raise Error, "snapshot #{@snapshot_path} is #{age_hours.round(1)} hours old (limit #{config.snapshot_max_age_hours}); take a new one"
    end

    def intelliflo = @intelliflo ||= Clients::Intelliflo.new(config: config)

    def high_level(writable:)
      return @high_level if @high_level
      Clients::HighLevel.new(config: config, writable: writable)
    end

    def zoom(writable:)
      return @zoom if @zoom
      Clients::Zoom.new(config: config, writable: writable)
    end

    def link_store
      @link_store ||= defined?(IoSync::Link) ? IoSync::Link.store : MemoryLinkStore.new
    end

    def deliver(report)
      mailer = @mailer == :default ? (defined?(IoSync::ReportMailer) ? IoSync::ReportMailer : nil) : @mailer
      return unless mailer
      { report: true, summary: !config.summary_mail_to.to_s.empty? }.each do |kind, wanted|
        next unless wanted && mailer.respond_to?(kind)
        begin
          mailer.public_send(kind, report).deliver_now
        rescue StandardError => e
          config.logger.error("IoSync: could not deliver #{kind} for #{report.run_id}: #{e.class}: #{e.message}")
        end
      end
    end
  end
end
