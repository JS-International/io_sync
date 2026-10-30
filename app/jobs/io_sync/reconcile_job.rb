module IoSync
  # Nightly entry point. Defaults to plan mode. An "apply" run with the kill
  # switch (IoSync.config.writes_enabled) off runs as a plan instead, so
  # turning the switch off always yields a report rather than a failed job.
  class ReconcileJob < ApplicationJob
    queue_as :io_sync
    limits_concurrency to: 1, key: "io_sync" if respond_to?(:limits_concurrency)

    def perform(mode = "plan", approved_report_path = nil)
      mode = mode.to_sym
      if mode == :apply && !IoSync.config.writes_enabled
        IoSync.config.logger&.info("io_sync: apply requested but writes are disabled; planning instead")
        mode = :plan
      end
      approved = approved_report_path && Report.from_file(approved_report_path)
      report = IoSync.reconcile(mode: mode, approved: approved)
      raise Aborted, report.error if report.aborted?
      report.summary_line
    end
  end
end
