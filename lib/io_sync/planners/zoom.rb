module IoSync
  module Planners
    class Zoom
      attr_reader :snapshot, :config, :plan, :links

      def initialize(snapshot, config:, plan:, links:)
        @snapshot = snapshot
        @config = config
        @plan = plan
        @links = links
        @registry = NumberRegistry.new
        Array(snapshot.zoom_account_numbers).each do |n|
          @registry.seed(n["number"].to_s, "account:#{n.dig('assignee', 'name') || n['status']}")
        end
        snapshot.zoom_contacts.each do |z|
          Array(z["phone_numbers"]).each { |n| @registry.seed(n.to_s, z["external_contact_id"]) }
        end
      end

      def call
        snapshot.io_records.each { |record| plan_record(record) }
        plan
      end

      private

      def plan_record(record)
        zoom_id = links[record.io_id]&.zoom_external_contact_id
        current = zoom_id && snapshot.zoom_by_external_id[zoom_id]
        owner = zoom_id || "io:#{record.io_id}"
        mapper = ZoomMapper.new(record, config: config, registry: @registry, owner: owner)

        if record.fetch_error
          return unless current || mapper.status_eligible?
          return plan.add(target: :zoom, kind: :skip, io_id: record.io_id, io_type: record.type.to_s, io_name: record.label,
                          remote_id: zoom_id, reason: "Intelliflo fetch failed: #{record.fetch_error}")
        end

        if current && mapper.excluded_status?
          return plan.add(target: :zoom, kind: :delete, io_id: record.io_id, io_type: record.type.to_s, io_name: record.label,
                          remote_id: zoom_id, reason: "service status #{record.service_status}", payload: nil)
        end
        return unless mapper.status_eligible?

        blocked = mapper.blocked_numbers.map { |n| "#{n} (already on #{holder(n)})" }
        if mapper.claimable_numbers.empty?
          return if record.numbers.empty? && current.nil?
          reason = record.numbers.empty? ? "no valid phone number" : "no claimable number: #{blocked.join(', ')}"
          plan.note(:zoom_number_conflicts, io_id: record.io_id, name: record.label, detail: "not added to Zoom: #{blocked.join(', ')}") if blocked.any?
          return plan.add(target: :zoom, kind: :skip, io_id: record.io_id, io_type: record.type.to_s, io_name: record.label,
                          remote_id: zoom_id, reason: reason)
        end
        if blocked.any?
          plan.note(:zoom_number_conflicts, io_id: record.io_id, name: record.label, detail: "synced without #{blocked.join(', ')}")
        end

        if current.nil?
          plan.add(target: :zoom, kind: :create, io_id: record.io_id, io_type: record.type.to_s, io_name: record.label, email: record.email,
                   payload: mapper.payload, diff: mapper.diff(nil))
        else
          diff = mapper.diff(current)
          if diff.empty?
            plan.add(target: :zoom, kind: :noop, io_id: record.io_id, io_type: record.type.to_s, io_name: record.label, remote_id: zoom_id, payload: nil)
          else
            plan.add(target: :zoom, kind: :update, io_id: record.io_id, io_type: record.type.to_s, io_name: record.label, email: record.email,
                     remote_id: zoom_id, payload: mapper.payload, diff: diff)
          end
        end
      end

      # Who holds a number in Zoom: a Zoom contact id or "io:<id>" for a
      # record that claimed it earlier in this run.
      def holder(number)
        owner = @registry.owner(number).to_s
        if owner.start_with?("account:")
          "the firm's own Zoom number (#{owner.delete_prefix('account:')})"
        elsif owner.start_with?("io:")
          snapshot.io_by_id[owner.delete_prefix("io:").to_i]&.label || owner
        else
          zoom = snapshot.zoom_by_external_id[owner]
          zoom ? "Zoom contact #{owner} \"#{zoom['name']}\"#{zoom['id'].to_s.empty? ? '' : " (IO #{zoom['id']})"}" : "Zoom contact #{owner}"
        end
      end
    end
  end
end
