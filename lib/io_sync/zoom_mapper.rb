module IoSync
  # Builds the Zoom external contact payload for one IO client. Ported from the
  # old IoZoom module. The "id" field carries the Intelliflo id.
  class ZoomMapper
    attr_reader :record, :config

    def initialize(record, config:, registry:, owner:)
      @record = record
      @config = config
      @registry = registry
      @owner = owner
    end

    # Clients only (unless configured otherwise), persons, with a present
    # service status that is not excluded.
    def status_eligible?
      return false if record.lead? && !config.zoom_include_leads
      return false unless record.person?
      return false unless record.service_status_present?
      !config.zoom_exclude_statuses.include?(record.service_status)
    end

    def excluded_status? = config.zoom_exclude_statuses.include?(record.service_status)

    def claimable_numbers
      @claimable_numbers ||= record.numbers.select { |n| @registry.claim(n, @owner) }
    end

    def blocked_numbers
      record.numbers - claimable_numbers
    end

    def payload
      {
        "name" => name_string,
        "email" => record.email,
        "id" => record.io_id.to_s,
        "description" => description,
        "phone_numbers" => claimable_numbers
      }
    end

    def description
      admin_adviser = [ record.admin_first_name_clean, record.adviser_first_name ].compact.reject(&:empty?).join("/")
      [ admin_adviser, record.service_status ].reject { |s| s.to_s.empty? }.join(" | ")
    end

    def name_string
      if record.vulnerable?
        "*V* #{record.name} | #{description} *V*"
      else
        "#{record.name} | #{description}".gsub(/\s*BLANK\s*/, "")
      end
    end

    def diff(current)
      return { "(new)" => [ nil, "create" ] } if current.nil?
      desired = payload
      changes = {}
      %w[name email description id].each do |key|
        # Zoom ignores a null on PATCH, so an empty value can never clear a field.
        next if desired[key].nil?
        a = current[key].to_s.strip
        b = desired[key].to_s.strip
        changes[key] = [ current[key], desired[key] ] if a != b
      end
      cur = Array(current["phone_numbers"]).map(&:to_s).sort
      if cur != desired["phone_numbers"].sort
        changes["phone_numbers"] = [ current["phone_numbers"], desired["phone_numbers"] ]
      end
      changes
    end
  end
end
