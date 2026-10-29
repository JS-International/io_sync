module IoSync
  # A plain link row, independent of ActiveRecord so planners stay pure.
  LinkRow = Struct.new(:io_id, :io_type, :hl_contact_id, :zoom_external_contact_id, keyword_init: true) do
    def to_h = { io_id: io_id, io_type: io_type.to_s, hl_contact_id: hl_contact_id, zoom_external_contact_id: zoom_external_contact_id }
  end

  # Everything one run reads, in memory. Built by SnapshotLoader.
  class Snapshot
    attr_accessor :io_listed_ids, :custom_field_names, :stats, :problems, :scoped, :zoom_account_numbers
    attr_reader :io_records, :hl_contacts, :zoom_contacts, :links

    def io_records=(v)
      @io_by_id = @io_by_email = nil
      @io_records = v
    end

    def hl_contacts=(v)
      @hl_by_id = @hl_by_email = nil
      @hl_contacts = v
    end

    def zoom_contacts=(v)
      @zoom_by_external_id = @zoom_by_io_id = nil
      @zoom_contacts = v
    end

    def links=(v)
      @io_id_by_hl = nil
      @links = v
    end

    def initialize
      @io_records = []
      @io_listed_ids = { client: Set.new, lead: Set.new }
      @hl_contacts = []
      @zoom_contacts = []
      @zoom_account_numbers = []
      @links = {}
      @custom_field_names = {}
      @stats = {}
      @problems = []
      @scoped = false
    end

    def io_by_id = @io_by_id ||= io_records.to_h { |r| [ r.io_id, r ] }
    def hl_by_id = @hl_by_id ||= hl_contacts.to_h { |c| [ c["id"], c ] }

    def hl_by_email
      @hl_by_email ||= hl_contacts.group_by { |c| c["email"].to_s.strip.downcase }.tap { |h| h.delete("") }
    end

    def io_by_email
      @io_by_email ||= io_records.group_by(&:email).tap { |h| h.delete(nil) }
    end

    def zoom_by_external_id = @zoom_by_external_id ||= zoom_contacts.to_h { |c| [ c["external_contact_id"], c ] }
    def zoom_by_io_id = @zoom_by_io_id ||= zoom_contacts.group_by { |c| c["id"].to_s }.tap { |h| h.delete("") }

    # io_id => hl contact id, from link rows (the planner replaces this with the
    # effective map after link actions).
    def hl_link_for(io_id) = links[io_id]&.hl_contact_id
    def zoom_link_for(io_id) = links[io_id]&.zoom_external_contact_id

    def hl_contact_linked_to(hl_contact_id)
      @io_id_by_hl ||= links.values.to_h { |l| [ l.hl_contact_id, l.io_id ] }.tap { |h| h.delete(nil) }
      @io_id_by_hl[hl_contact_id]
    end

    # Everything read from IO, HL and Zoom, as plain JSON. Links are included
    # for exploring but a cached run always takes them from the link store.
    # The file holds personal data: it is written owner-read-only.
    def to_h
      {
        "saved_at" => Time.now.utc.iso8601, "version" => IoSync::VERSION, "scoped" => scoped,
        "io_listed_ids" => io_listed_ids.transform_keys(&:to_s).transform_values(&:to_a),
        "io_records" => io_records.map(&:to_h), "hl_contacts" => hl_contacts, "zoom_contacts" => zoom_contacts, "zoom_account_numbers" => zoom_account_numbers,
        "custom_field_names" => custom_field_names, "links" => links.values.map { |l| l.to_h.transform_keys(&:to_s) },
        "stats" => stats, "problems" => problems
      }
    end

    def self.from_h(h)
      new.tap do |s|
        s.scoped = h["scoped"]
        s.io_listed_ids = { client: h.dig("io_listed_ids", "client").to_set, lead: h.dig("io_listed_ids", "lead").to_set }
        s.io_records = h["io_records"].map { |r| IoRecord.from_h(r) }
        s.hl_contacts = h["hl_contacts"]
        s.zoom_contacts = h["zoom_contacts"]
        s.zoom_account_numbers = h["zoom_account_numbers"] || []
        s.custom_field_names = h["custom_field_names"] || {}
        s.links = Array(h["links"]).to_h { |l| [ l["io_id"], LinkRow.new(**l.transform_keys(&:to_sym)) ] }
        s.stats = (h["stats"] || {}).transform_keys(&:to_sym)
        s.problems = h["problems"] || []
      end
    end

    def save(path)
      File.open(path, "w", 0o600) { |f| f.write(JSON.generate(to_h)) }
      path
    end

    def self.load_file(path) = from_h(JSON.parse(File.read(path)))

    # For exploring a saved snapshot: every IO record, HL contact and Zoom
    # contact whose name, email or id matches, grouped by IO id where linked.
    # Returns [{ io:, link:, hl:, zoom: }]; unmatched remote records come back
    # with io: nil.
    def find(query)
      q = query.to_s.strip.downcase
      match = ->(*values) { values.compact.any? { |v| v.to_s.downcase.include?(q) } }
      hl_name = ->(c) { [ c["firstName"], c["lastName"] ].compact.join(" ") }

      ios = io_records.select { |r| match.call(r.io_id, r.label, r.email, *r.emails) }
      hls = hl_contacts.select { |c| match.call(c["id"], hl_name.call(c), c["contactName"], c["email"]) }
      zooms = zoom_contacts.select { |c| match.call(c["external_contact_id"], c["id"], c["name"], c["email"]) }

      io_ids = ios.map(&:io_id) +
               hls.map { |c| hl_contact_linked_to(c["id"]) } +
               zooms.map { |c| links.values.detect { |l| l.zoom_external_contact_id == c["external_contact_id"] }&.io_id || c["id"].to_s[/\A\d+\z/]&.to_i }
      io_ids = io_ids.compact.uniq

      results = io_ids.map do |id|
        link = links[id]
        { io: io_by_id[id], link: link,
          hl: link&.hl_contact_id && hl_by_id[link.hl_contact_id],
          zoom: (link&.zoom_external_contact_id && zoom_by_external_id[link.zoom_external_contact_id]) || zoom_by_io_id[id.to_s]&.first }
      end
      seen_hl = results.map { |r| r[:hl]&.dig("id") }.compact
      seen_zoom = results.map { |r| r[:zoom]&.dig("external_contact_id") }.compact
      results + hls.reject { |c| seen_hl.include?(c["id"]) }.map { |c| { io: nil, link: nil, hl: c, zoom: nil } } +
        zooms.reject { |c| seen_zoom.include?(c["external_contact_id"]) }.map { |c| { io: nil, link: nil, hl: nil, zoom: c } }
    end
  end
end
