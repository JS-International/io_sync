module IoSync
  # Builds the HighLevel payload for one IO record and diffs it against the
  # live contact. Rules ported from the old IoHl module.
  class HlMapper
    CONTACT_KEYS = %w[firstName lastName email dateOfBirth phone additionalPhones address1 city country state postalCode type source].freeze
    DND_CHANNELS = %w[Email FB GMB SMS Call WhatsApp].freeze

    attr_reader :record, :current, :config

    def initialize(record, config:, current: nil, custom_field_names: {})
      @record = record
      @config = config
      @current = current
      @custom_field_names = custom_field_names
    end

    def payload
      contact_fields.merge("customFields" => custom_fields)
    end

    def contact_fields
      address = record.home_address(country_code_map: config.country_code_map)
      fields = {
        "firstName" => strip(record.salutation) || strip(record.first_name),
        "lastName" => strip(record.last_name),
        "email" => record.email,
        "dateOfBirth" => record.date_of_birth,
        "phone" => record.phone,
        "additionalPhones" => record.additional_phones,
        "address1" => address["line1"],
        "city" => address["city"],
        "country" => address["country"],
        "state" => address["county"],
        "postalCode" => address["postalCode"],
        "type" => type,
        "source" => source
      }
      fields.delete("type") if fields["type"].nil?
      fields
    end

    def type
      mapped = config.hl_type_map[record.service_status]
      return mapped if mapped
      fallback = config.hl_type_fallback
      fallback == :keep_current ? current&.dig("type") : fallback
    end

    def source
      existing = current && current["source"].to_s.strip
      existing.nil? || existing.empty? ? config.hl_default_source : existing
    end

    # IO-owned fields are rebuilt from IO; every other custom field on the HL
    # contact is passed through untouched.
    def custom_fields
      passthrough_custom_fields + io_custom_fields
    end

    def io_custom_fields
      ids = config.hl_custom_field_ids
      fields = [
        { "id" => ids[:courtesy_title], "value" => record.title },
        { "id" => ids[:salutation], "value" => strip(record.salutation) || strip(record.first_name) },
        { "id" => ids[:category], "value" => record.category },
        { "id" => ids[:service_status], "value" => record.service_status },
        { "id" => ids[:adviser], "value" => record.adviser_first_name },
        { "id" => ids[:customer_crm], "value" => record.admin_first_name_clean }
      ].reject { |cf| blank?(cf["value"]) }
      # Clear adviser / admin in HL when IO no longer has one, but only if HL holds the field.
      fields << { "id" => ids[:adviser], "value" => nil } if current_has?(ids[:adviser]) && record.adviser_first_name.nil?
      fields << { "id" => ids[:customer_crm], "value" => nil } if current_has?(ids[:customer_crm]) && record.admin_first_name_clean.nil?
      # Category missing in IO but set in HL: keep the HL value.
      if current_has?(ids[:category]) && blank?(record.category)
        fields << { "id" => ids[:category], "value" => current_custom_value(ids[:category]) }
      end
      fields
    end

    def passthrough_custom_fields
      return [] unless current
      Array(current["customFields"]).reject { |cf| config.owned_custom_field_ids.include?(cf["id"]) }
                                    .map { |cf| { "id" => cf["id"], "value" => cf["value"] } }
    end

    # { "phone" => [old, new], "customFields.Adviser" => [old, new] }
    def diff
      return { "(new)" => [ nil, "create" ] } if current.nil?
      changes = {}
      desired = contact_fields
      CONTACT_KEYS.each do |key|
        next unless desired.key?(key)
        # HL fills an empty country with the location's default, so clearing it never sticks.
        next if key == "country" && desired[key].nil?
        a = normalise_for_compare(key, current[key])
        b = normalise_for_compare(key, desired[key])
        changes[key] = [ current[key], desired[key] ] if a != b
      end
      cur_cf = custom_values(Array(current["customFields"]))
      new_cf = custom_values(custom_fields)
      # Only fields in the payload change; HL leaves omitted ones as they are.
      # An explicit nil (adviser, customer CRM) does clear.
      new_cf.each_key do |id|
        next if same_value?(cur_cf[id], new_cf[id])
        changes["customFields.#{@custom_field_names[id] || id}"] = [ cur_cf[id], new_cf[id] ]
      end
      changes
    end

    def up_to_date? = diff.empty?

    def plan_tags = record.plan_tags

    def current_plan_tags
      Array(current && current["tags"]).select { |t| t.to_s.start_with?("plan - ") }
    end

    def tags_to_add = plan_tags - current_plan_tags
    def tags_to_remove = current_plan_tags - plan_tags

    def dnd_needed?
      settings = current && current["dndSettings"]
      return true unless settings.is_a?(Hash)
      DND_CHANNELS.any? { |ch| settings.dig(ch, "status") != "active" }
    end

    def dnd_payload(time)
      message = "Updated by Intelliflo #{time}"
      DND_CHANNELS.to_h { |ch| [ ch, { "status" => "active", "message" => message } ] }
    end

    private

    def strip(value)
      v = value.to_s.strip
      v.empty? ? nil : v
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def current_has?(field_id)
      current && Array(current["customFields"]).any? { |cf| cf["id"] == field_id }
    end

    def current_custom_value(field_id)
      Array(current["customFields"]).detect { |cf| cf["id"] == field_id }&.dig("value")
    end

    def custom_values(list)
      list.each_with_object({}) { |cf, h| h[cf["id"]] = cf["value"] }
    end

    def same_value?(a, b)
      na = blank?(a) ? nil : a
      nb = blank?(b) ? nil : b
      na.is_a?(Array) && nb.is_a?(Array) ? na.sort == nb.sort : na == nb
    end

    def normalise_for_compare(key, value)
      case key
      when "additionalPhones"
        Array(value).map { |p| p.is_a?(Hash) ? p["phone"] : p }.compact.sort
      when "dateOfBirth"
        # HL search returns epoch milliseconds; GET returns "YYYY-MM-DD"; IO sends "YYYY-MM-DD".
        return Time.at(value / 1000).utc.strftime("%Y-%m-%d") if value.is_a?(Integer)
        v = value.to_s
        v.match?(/\A\d{4}-\d{2}-\d{2}/) ? v[0, 10] : (v.empty? ? nil : v)
      else
        blank?(value) ? nil : value.to_s
      end
    end
  end
end
