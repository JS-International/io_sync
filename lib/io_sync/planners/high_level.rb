module IoSync
  module Planners
    class HighLevel
      attr_reader :snapshot, :config, :plan, :links

      def initialize(snapshot, config:, plan:, links:, time: Time.now)
        @snapshot = snapshot
        @config = config
        @plan = plan
        @links = links
        @time = time
      end

      def call
        snapshot.io_records.each { |record| plan_record(record) }
        plan_status_dnd
        plan
      end

      private

      def plan_record(record)
        hl_id = links[record.io_id]&.hl_contact_id
        current = hl_id && snapshot.hl_by_id[hl_id]
        candidate = record.email && (record.allowlisted?(config) || current)
        return unless candidate
        return skip(record, current, "Intelliflo fetch failed: #{record.fetch_error}") if record.fetch_error

        mapper = HlMapper.new(record, config: config, current: current, custom_field_names: snapshot.custom_field_names)
        return if email_conflict?(record, current)

        if current.nil?
          plan.add(target: :hl, kind: :create, io_id: record.io_id, io_type: record.type.to_s, io_name: record.label, email: record.email,
                   payload: mapper.payload, diff: mapper.diff)
        elsif mapper.up_to_date?
          plan.add(target: :hl, kind: :noop, io_id: record.io_id, io_type: record.type.to_s, io_name: record.label, email: record.email,
                   remote_id: current["id"], payload: nil)
        else
          plan.add(target: :hl, kind: :update, io_id: record.io_id, io_type: record.type.to_s, io_name: record.label, email: record.email,
                   remote_id: current["id"], payload: mapper.payload, diff: mapper.diff)
        end

        plan_tags(record, current, mapper)
      end

      # HL allows one email per location. Another contact holding this record's
      # email blocks a create, or an update that changes the email.
      def email_conflict?(record, current)
        return false if current && current["email"].to_s.strip.downcase == record.email
        owner = (snapshot.hl_by_email[record.email] || []).reject { |c| current && c["id"] == current["id"] }.first
        return false unless owner
        owner_io_id = links.values.detect { |l| l.hl_contact_id == owner["id"] }&.io_id
        owner_record = owner_io_id && snapshot.io_by_id[owner_io_id]
        # A lead sharing an email with a synced record (a spouse, or the client
        # it was converted to) is expected and not worth a line in the report.
        return true if record.lead? && owner_io_id
        target = current ? "HL contact #{current['id']} cannot take this email" : "a new HL contact cannot be created"
        reason =
          if owner_io_id
            "email #{record.email} is already on HL contact #{owner['id']}, linked to IO #{owner_io_id}#{owner_record ? " #{owner_record.label}" : ''}, " \
            "so #{target}. Two IO records share this email; only one can sync to HL."
          else
            "email #{record.email} is already on HL contact #{owner['id']}, which is not linked to any IO record, so #{target}. " \
            "Merge or delete the duplicate in HL."
          end
        plan.add(target: :hl, kind: :conflict, io_id: record.io_id, io_type: record.type.to_s, io_name: record.label, email: record.email,
                 remote_id: current && current["id"], reason: reason)
        plan.problem("#{record.label}: #{reason}")
        true
      end

      def skip(record, current, reason)
        plan.add(target: :hl, kind: :skip, io_id: record.io_id, io_type: record.type.to_s, io_name: record.label, email: record.email,
                 remote_id: current && current["id"], reason: reason)
      end

      # Plan tags are managed only for clients whose plans were fetched. A
      # record with no in-force plans has its stale "plan - " tags removed.
      def plan_tags(record, current, mapper)
        return unless record.client? && !record.plans.nil?
        add = mapper.tags_to_add
        remove = mapper.tags_to_remove
        remote_id = current && current["id"]
        unless add.empty?
          plan.add(target: :hl, kind: :add_tags, io_id: record.io_id, io_type: record.type.to_s, io_name: record.label, email: record.email,
                   remote_id: remote_id, payload: { "tags" => add }, diff: { "tags" => [ mapper.current_plan_tags, mapper.plan_tags ] })
        end
        unless remove.empty?
          plan.add(target: :hl, kind: :remove_tags, io_id: record.io_id, io_type: record.type.to_s, io_name: record.label, email: record.email,
                   remote_id: remote_id, payload: { "tags" => remove }, diff: { "tags" => [ mapper.current_plan_tags, mapper.plan_tags ] })
        end
      end

      # Every linked client whose service status is in hl_dnd_statuses (deceased,
      # restricted processing) gets all six DND channels set, whether or not it
      # still has an email.
      def plan_status_dnd
        links.values.select(&:hl_contact_id).each do |l|
          record = snapshot.io_by_id[l.io_id] or next
          next unless config.hl_dnd_statuses.include?(record.service_status)
          current = snapshot.hl_by_id[l.hl_contact_id] or next
          mapper = HlMapper.new(record, config: config, current: current)
          next unless mapper.dnd_needed?
          plan.add(target: :hl, kind: :dnd, io_id: record.io_id, io_type: record.type.to_s, io_name: record.label, email: record.email,
                   remote_id: current["id"], payload: { "dndSettings" => mapper.dnd_payload(@time) },
                   diff: { "dndSettings" => [ current["dndSettings"], "all channels active" ] }, reason: record.service_status.downcase)
        end
      end
    end
  end
end
