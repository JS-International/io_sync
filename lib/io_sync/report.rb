module IoSync
  # The reviewable outcome of a run: the plan, what was applied, and run
  # metadata. Serialises to JSON so a reviewed plan can be handed back to
  # a later apply run.
  class Report
    ATTRS = %i[run_id mode status started_at finished_at writes_enabled approved_from stats problems notes actions error].freeze
    attr_accessor(*ATTRS)

    def initialize(run_id:, mode:, started_at:, writes_enabled:, approved_from: nil)
      @run_id = run_id
      @mode = mode.to_sym
      @status = :running
      @started_at = started_at
      @finished_at = nil
      @writes_enabled = writes_enabled
      @approved_from = approved_from
      @stats = {}
      @problems = []
      @actions = []
      @notes = {}
      @error = nil
    end

    def load_plan(plan, snapshot = nil)
      @actions = plan.actions
      @problems = (snapshot ? snapshot.problems : []) + plan.problems
      @stats = (snapshot ? snapshot.stats : {}).merge(plan.stats)
      @notes = plan.notes
      self
    end

    def counts
      actions.group_by(&:target).transform_values { |as| as.group_by(&:kind).transform_values(&:size) }
    end

    def result_counts
      actions.map { |a| a.result && a.result[:status] }.compact.tally
    end

    def writes = actions.select(&:write?)
    def digests = writes.map(&:digest).to_set
    def aborted? = status == :aborted

    def summary_line
      c = counts
      parts = %i[hl zoom link].map do |t|
        next unless c[t]
        "#{t}: " + c[t].map { |k, v| "#{v} #{k}" }.join(", ")
      end.compact
      "#{mode} run #{run_id} #{status}; #{parts.join(' | ')}; #{problems.size} problems" + (error ? "; error: #{error}" : "")
    end

    def to_h
      {
        run_id: run_id, mode: mode, status: status, started_at: started_at&.iso8601, finished_at: finished_at&.iso8601,
        writes_enabled: writes_enabled, approved_from: approved_from, stats: stats, problems: problems, notes: notes,
        counts: counts, result_counts: result_counts, error: error, actions: actions.map(&:to_h)
      }
    end

    def to_json(*args) = JSON.pretty_generate(to_h, *args)

    def self.from_json(json)
      h = JSON.parse(json).transform_keys(&:to_sym)
      report = new(run_id: h[:run_id], mode: h[:mode], started_at: h[:started_at] && Time.parse(h[:started_at]),
                   writes_enabled: h[:writes_enabled], approved_from: h[:approved_from])
      report.status = h[:status]&.to_sym
      report.finished_at = h[:finished_at] && Time.parse(h[:finished_at])
      report.stats = h[:stats] || {}
      report.problems = h[:problems] || []
      report.notes = (h[:notes] || {}).to_h { |k, items| [ k.to_sym, items.map { |i| i.transform_keys(&:to_sym) } ] }
      report.error = h[:error]
      report.actions = Array(h[:actions]).map { |a| Action.from_h(a) }
      report
    end

    def self.from_file(path) = from_json(File.read(path))
  end
end
