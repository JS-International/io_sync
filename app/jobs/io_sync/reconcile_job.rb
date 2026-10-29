module IoSync
  # Nightly entry point. Defaults to plan mode. Pass "apply" only once the
  # kill switch (IoSync.config.writes_enabled) is on and plans have been reviewed.
  class ReconcileJob < ApplicationJob
    queue_as :io_sync
    limits_concurrency to: 1, key: "io_sync" if respond_to?(:limits_concurrency)

    def perform(mode = "plan", approved_report_path = nil)
      approved = approved_report_path && Report.from_file(approved_report_path)
      report = IoSync.reconcile(mode: mode.to_sym, approved: approved)
      raise Aborted, report.error if report.aborted?
      report.summary_line
    end
  end
end
