module IoSync
  # One read pass over Intelliflo, HighLevel and Zoom. Reads only.
  class SnapshotLoader
    attr_reader :config

    def initialize(config:, intelliflo:, high_level:, zoom:, link_store:, scope: nil)
      @config = config
      @intelliflo = intelliflo
      @high_level = high_level
      @zoom = zoom
      @link_store = link_store
      @scope = scope
    end

    def load
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      snapshot = Snapshot.new
      snapshot.scoped = !@scope.nil?
      snapshot.links = @link_store.all.to_h { |l| [ l.io_id, l ] }

      load_intelliflo(snapshot)
      confirm_gone(snapshot) unless snapshot.scoped
      load_high_level(snapshot)
      load_zoom(snapshot)

      snapshot.stats.merge!(
        io_clients_listed: snapshot.io_listed_ids[:client].size,
        io_leads_listed: snapshot.io_listed_ids[:lead].size,
        io_persons: snapshot.io_records.size,
        io_fetch_failures: snapshot.io_records.count(&:fetch_error),
        io_gone_confirmed: snapshot.io_gone_ids.size,
        hl_contacts: snapshot.hl_contacts.size,
        zoom_contacts: snapshot.zoom_contacts.size,
        links: snapshot.links.size,
        api_calls: { intelliflo: @intelliflo.calls.value, high_level: @high_level.calls.value, zoom: @zoom.calls.value },
        load_seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)
      )
      snapshot
    end

    # Re-reads HL and Zoom into a snapshot whose IO side came from a file, so
    # an apply diffs against the live remote records. Costs about 15 calls.
    def refresh_remote(snapshot)
      load_high_level(snapshot)
      load_zoom(snapshot)
      snapshot.links = @link_store.all.to_h { |l| [ l.io_id, l ] }
      snapshot.stats.merge!(
        hl_contacts: snapshot.hl_contacts.size, zoom_contacts: snapshot.zoom_contacts.size, links: snapshot.links.size,
        remote_refreshed_at: Time.now.utc.iso8601
      )
      snapshot
    end

    private

    def load_intelliflo(snapshot)
      clients, leads = list_intelliflo(snapshot)
      records = clients.map { |d| IoRecord.new(details: d, type: :client) } +
                leads.map { |d| IoRecord.new(details: d, type: :lead) }
      records.select!(&:person?)
      records.sort_by!(&:io_id)

      pool = Concurrent::FixedThreadPool.new(config.io_concurrency)
      futures = records.map do |record|
        Concurrent::Future.execute(executor: pool) { fetch_sub_resources(record, snapshot) }
      end
      futures.each(&:value)
      pool.shutdown
      pool.wait_for_termination(600)

      failures = records.count(&:fetch_error)
      if records.any? && failures.to_f / records.size > config.io_failure_threshold
        raise Aborted, "#{failures} of #{records.size} Intelliflo records failed to load; not planning against incomplete data"
      end

      load_admins(records)
      snapshot.io_records = records
    end

    # A linked record missing from both lists counts as archived or deleted
    # only once Intelliflo answers 404 for it, so a short list cannot unlink
    # anyone. Nothing is checked for a type whose list looks broken (over the
    # prune cap, or under half the rows); the planner reports those instead.
    def confirm_gone(snapshot)
      listed = snapshot.io_listed_ids.values.reduce(Set.new, :|)
      snapshot.links.values.group_by { |l| l.io_type.to_s }.each do |type, rows|
        next unless %w[client lead].include?(type)
        missing = rows.reject { |l| listed.include?(l.io_id) }
        next if missing.empty? || missing.size > config.prune_cap(rows.size)
        next if snapshot.io_listed_ids[type.to_sym].size < rows.size / 2
        missing.each do |l|
          @intelliflo.public_send(type, l.io_id)
        rescue ApiError => e
          snapshot.io_gone_ids << l.io_id if e.status == 404
        end
      end
    end

    def list_intelliflo(snapshot)
      if @scope
        clients = Array(@scope[:client_ids]).map { |id| @intelliflo.client(id) }.compact
        leads = Array(@scope[:lead_ids]).map { |id| @intelliflo.lead(id) }.compact
      else
        clients = @intelliflo.clients
        leads = @intelliflo.leads
      end
      snapshot.io_listed_ids[:client] = clients.map { |c| c["id"] }.to_set
      snapshot.io_listed_ids[:lead] = leads.map { |c| c["id"] }.to_set
      [ clients, leads ]
    end

    # Contact details for every person; addresses, plans and vulnerability only
    # for clients that could reach HL or Zoom.
    def fetch_sub_resources(record, snapshot)
      record.contactdetails = @intelliflo.contactdetails(record.type, record.io_id)
      return unless record.client? && needs_full_fetch?(record, snapshot)
      record.addresses = @intelliflo.addresses(record.io_id)
      record.plans = @intelliflo.plans(record.io_id)
      record.vulnerability = @intelliflo.vulnerability(record.io_id)
    rescue StandardError => e
      record.fetch_error = "#{e.class}: #{e.message}"
    end

    def needs_full_fetch?(record, snapshot)
      record.allowlisted?(config) ||
        snapshot.links.key?(record.io_id) ||
        (record.service_status_present? && !config.zoom_exclude_statuses.include?(record.service_status))
    end

    def load_admins(records)
      ids = records.map(&:servicing_administrator_id).compact.uniq
      return if ids.empty?
      users = @intelliflo.users(ids).to_h { |u| [ u["id"], u ] }
      records.each do |r|
        user = users[r.servicing_administrator_id]
        r.admin_first_name = user && user["firstName"]
      end
    end

    def load_high_level(snapshot)
      snapshot.hl_contacts = @high_level.search_contacts
      snapshot.custom_field_names = @high_level.custom_fields.to_h { |f| [ f["id"], f["name"] ] }
    end

    def load_zoom(snapshot)
      snapshot.zoom_contacts = @zoom.external_contacts
      snapshot.zoom_account_numbers = @zoom.account_numbers
    rescue ApiError => e
      raise if snapshot.zoom_contacts.empty?
      snapshot.problems << "Could not read the Zoom account's own numbers (#{e.status}); creates holding one of them will fail"
    end
  end
end
