module IoSync
  class ReportMailer < ApplicationMailer
    # Full technical report with the JSON plan attached, for whoever reviews and approves runs.
    def report(report)
      @report = report
      @changes = report.actions.reject(&:noop?)
      from = IoSync.config.mail_from
      mail(to: IoSync.config.mail_to, from: from, subject: subject_for(report)) do |format|
        attachments["io_sync-#{report.run_id}.json"] = { mime_type: "application/json", content: report.to_json }
        format.html
      end
    end

    # Plain-English summary for the business: what changed, who was moved to
    # DND, and the oddities someone should look at.
    def summary(report)
      @report = report
      @applied = report.status == :applied
      @changed = report.writes.select { |a| !@applied || a.result&.dig(:status) == :ok }
      @dnd = report.actions.select { |a| a.target == :hl && a.kind == :dnd }
      dnd_done = @applied ? @dnd.count { |a| a.result&.dig(:status) == :ok } : @dnd.size
      @lost_links = report.actions.select { |a| a.target == :link && a.kind == :unlink }
      @relinked = report.actions.select { |a| a.target == :link && a.kind == :relink }
      @zoom_deleted = report.actions.select { |a| a.target == :zoom && a.kind == :delete }
      @email_conflicts = report.actions.select { |a| a.target == :hl && (a.kind == :conflict || (a.kind == :skip && a.reason.to_s.include?("email"))) }
      # Fully blocked records are listed; records that synced with a shared
      # number left off (usually a partner's landline) are only counted.
      @numbers_blocked, @numbers_partial = Array(report.notes[:zoom_number_conflicts]).partition { |n| n[:detail].start_with?("not added") }
      @orphans = Array(report.notes[:hl_orphans])
      @failed = report.actions.select { |a| %i[error not_attempted].include?(a.result&.dig(:status)) }
      mail(to: IoSync.config.summary_mail_to, from: IoSync.config.mail_from,
           subject: "Intelliflo sync #{@applied ? 'completed' : (report.aborted? ? 'aborted' : 'plan (nothing changed)')}: " \
                    "#{@changed.size} changes, #{dnd_done} DND, #{oddity_count} to check")
    end

    private

    def subject_for(report)
      "IoSync #{report.mode} #{report.status}: #{report.writes.size} changes, #{report.problems.size} problems"
    end

    def oddity_count
      @lost_links.size + @email_conflicts.size + @numbers_blocked.size + @failed.size + @report.problems.size
    end
  end
end
