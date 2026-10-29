module IoSync
  module Planners
    # Decides link housekeeping before anything is pushed, and returns the
    # effective link map (io_id => LinkRow) the other planners work from.
    class Links
      attr_reader :snapshot, :config, :plan

      def initialize(snapshot, config:, plan:)
        @snapshot = snapshot
        @config = config
        @plan = plan
        @effective = snapshot.links.transform_values { |l| LinkRow.new(**l.to_h) }
      end

      def call
        prune_missing unless snapshot.scoped
        drop_dead_remote_ids
        relink_stale
        link_unlinked_hl_contacts
        adopt_zoom_contacts
        note_orphans unless snapshot.scoped
        @effective
      end

      private

      def hl_owner_io_id(hl_contact_id)
        @effective.values.detect { |l| l.hl_contact_id == hl_contact_id }&.io_id
      end

      # IO records absent from the IO list are archived or deleted. Unlink them
      # (the HL contact is left untouched) and delete their Zoom contact, with a
      # cap so a bad download cannot wipe the table.
      def prune_missing
        %i[client lead].each do |type|
          rows = @effective.values.select { |l| l.io_type.to_s == type.to_s }
          listed = snapshot.io_listed_ids[type]
          missing = rows.reject { |l| listed.include?(l.io_id) }
          next if missing.empty?
          allowed = [ config.prune_cap_min, (rows.size * config.prune_cap_fraction).ceil ].max
          if listed.size < rows.size / 2 || missing.size > allowed
            plan.problem("Skipped unlinking #{missing.size} #{type} rows missing from Intelliflo (cap #{allowed}, #{listed.size} listed): check the download")
            missing.each do |l|
              plan.add(target: :link, kind: :prune_skipped, io_id: l.io_id, io_type: l.io_type, remote_id: l.hl_contact_id,
                       reason: "missing from Intelliflo #{type} list but prune cap exceeded", payload: l.to_h.transform_keys(&:to_s))
            end
            next
          end
          missing.each do |l|
            if l.zoom_external_contact_id && snapshot.zoom_by_external_id[l.zoom_external_contact_id]
              plan.add(target: :zoom, kind: :delete, io_id: l.io_id, io_type: l.io_type, remote_id: l.zoom_external_contact_id,
                       io_name: snapshot.zoom_by_external_id[l.zoom_external_contact_id]["name"],
                       reason: "IO #{type} no longer listed by Intelliflo (archived or deleted)", payload: nil)
            end
            plan.add(target: :link, kind: :unlink, io_id: l.io_id, io_type: l.io_type, remote_id: l.hl_contact_id,
                     reason: "IO #{type} no longer listed by Intelliflo (archived or deleted)", payload: l.to_h.transform_keys(&:to_s))
            @effective.delete(l.io_id)
          end
        end
      end

      # Link rows pointing at HL or Zoom records that no longer exist.
      def drop_dead_remote_ids
        @effective.values.each do |l|
          record = snapshot.io_by_id[l.io_id]
          if l.hl_contact_id && !snapshot.hl_by_id.key?(l.hl_contact_id)
            plan.add(target: :link, kind: :unlink, io_id: l.io_id, io_type: l.io_type, io_name: record&.label, email: record&.email,
                     remote_id: l.hl_contact_id, reason: "HL contact #{l.hl_contact_id} no longer exists", payload: l.to_h.merge(hl_contact_id: nil).transform_keys(&:to_s))
            l.hl_contact_id = nil
          end
          if l.zoom_external_contact_id && !snapshot.zoom_by_external_id.key?(l.zoom_external_contact_id)
            plan.add(target: :link, kind: :unlink, io_id: l.io_id, io_type: l.io_type, io_name: record&.label, email: record&.email,
                     remote_id: l.zoom_external_contact_id, reason: "Zoom contact #{l.zoom_external_contact_id} no longer exists",
                     payload: l.to_h.merge(zoom_external_contact_id: nil).transform_keys(&:to_s))
            l.zoom_external_contact_id = nil
          end
          @effective.delete(l.io_id) if l.hl_contact_id.nil? && l.zoom_external_contact_id.nil?
        end
      end

      # A converted lead hands its HL contact to the client with the same email;
      # a record that lost its default email hands it to the one other record
      # that holds the HL contact's email. A record that merely changed its
      # email keeps the link so the new email gets pushed.
      def relink_stale
        @effective.values.select(&:hl_contact_id).each do |l|
          current = snapshot.io_by_id[l.io_id] or next
          hl = snapshot.hl_by_id[l.hl_contact_id] or next
          hl_email = hl["email"].to_s.strip.downcase
          next if hl_email.empty?
          others = (snapshot.io_by_email[hl_email] || []).reject { |r| r.io_id == current.io_id }
          candidates =
            if current.lead? then others.select(&:client?)
            elsif current.email.nil? then others
            else []
            end
          next unless candidates.size == 1
          target = candidates.first
          next if @effective[target.io_id]&.hl_contact_id
          plan.add(target: :link, kind: :relink, io_id: target.io_id, io_type: target.type.to_s, io_name: target.label, email: target.email,
                   remote_id: l.hl_contact_id,
                   reason: "HL contact #{l.hl_contact_id} (#{hl_email}) moved from IO #{current.io_id} #{current.label} " \
                           "(#{current.lead? ? 'converted lead' : 'no longer has that email'})",
                   payload: { "from_io_id" => current.io_id, "to_io_id" => target.io_id, "hl_contact_id" => l.hl_contact_id })
          l.hl_contact_id = nil
          @effective.delete(l.io_id) if l.zoom_external_contact_id.nil?
          row = @effective[target.io_id] || LinkRow.new(io_id: target.io_id, io_type: target.type.to_s)
          row.hl_contact_id = hl["id"]
          @effective[target.io_id] = row
        end
      end

      # Unlinked HL contacts whose email matches exactly one IO record (clients
      # preferred over leads). Ambiguity is reported, never guessed.
      def link_unlinked_hl_contacts
        linked_hl_ids = @effective.values.map(&:hl_contact_id).compact.to_set
        snapshot.hl_contacts.each do |hl|
          next if linked_hl_ids.include?(hl["id"])
          email = hl["email"].to_s.strip.downcase
          next if email.empty?
          matches = (snapshot.io_by_email[email] || []).reject { |r| @effective[r.io_id]&.hl_contact_id }
          next if matches.empty?
          clients = matches.select(&:client?)
          matches = clients if clients.any?
          if matches.size > 1
            plan.problem("HL contact #{hl['id']} (#{email}) matches several IO records: #{matches.map(&:label).join(', ')}; not linked")
            next
          end
          record = matches.first
          plan.add(target: :link, kind: :link, io_id: record.io_id, io_type: record.type.to_s, io_name: record.label, email: record.email,
                   remote_id: hl["id"], reason: "HL contact #{hl['id']} matched by email", payload: { "hl_contact_id" => hl["id"] })
          row = @effective[record.io_id] || LinkRow.new(io_id: record.io_id, io_type: record.type.to_s)
          row.hl_contact_id = hl["id"]
          @effective[record.io_id] = row
          linked_hl_ids << hl["id"]
        end
      end

      # HL contacts not linked to anything whose Client Ref ("<tenant>-<io id>",
      # written by an earlier integration) names an IO record Intelliflo no
      # longer lists. Nothing will update them again. Needs
      # hl_client_ref_field_id.
      def note_orphans
        field = config.hl_client_ref_field_id or return
        linked = @effective.values.map(&:hl_contact_id).compact.to_set
        listed = snapshot.io_listed_ids.values.reduce(Set.new, :|)
        snapshot.hl_contacts.each do |hl|
          next if linked.include?(hl["id"])
          ref = Array(hl["customFields"]).detect { |f| f["id"] == field }&.dig("value").to_s
          io_id = ref[/-(\d+)\z/, 1]&.to_i or next
          next if listed.include?(io_id)
          name = [ hl["firstName"], hl["lastName"] ].compact.join(" ")
          plan.note(:hl_orphans, io_id: io_id, name: "#{name} (HL #{hl['id']})",
                               detail: "#{hl['email'] || 'no email'}; Client Ref IO #{io_id} is not listed by Intelliflo (archived, deleted or restricted)")
        end
      end

      # Zoom contacts carry the IO id in their "id" field, so a missing Zoom
      # link can be recovered without guessing.
      def adopt_zoom_contacts
        linked_zoom_ids = @effective.values.map(&:zoom_external_contact_id).compact.to_set
        snapshot.io_records.each do |record|
          next if @effective[record.io_id]&.zoom_external_contact_id
          candidates = (snapshot.zoom_by_io_id[record.io_id.to_s] || []).reject { |z| linked_zoom_ids.include?(z["external_contact_id"]) }
          next if candidates.empty?
          if candidates.size > 1
            plan.problem("Zoom has #{candidates.size} contacts with id #{record.io_id} (#{record.label}); not adopted")
            next
          end
          zoom = candidates.first
          plan.add(target: :link, kind: :adopt, io_id: record.io_id, io_type: record.type.to_s, io_name: record.label, email: record.email,
                   remote_id: zoom["external_contact_id"], reason: "Zoom contact carries IO id #{record.io_id}",
                   payload: { "zoom_external_contact_id" => zoom["external_contact_id"] })
          row = @effective[record.io_id] || LinkRow.new(io_id: record.io_id, io_type: record.type.to_s)
          row.zoom_external_contact_id = zoom["external_contact_id"]
          @effective[record.io_id] = row
          linked_zoom_ids << zoom["external_contact_id"]
        end
      end
    end
  end
end
