module IoSync
  class Configuration
    SETTINGS = %i[
      hl_location_id hl_custom_field_ids hl_client_ref_field_id hl_service_status_allowlist hl_type_map hl_type_fallback
      hl_default_source hl_dnd_statuses zoom_exclude_statuses zoom_include_leads mail_to summary_mail_to mail_from writes_enabled
      io_concurrency io_requests_per_second io_failure_threshold prune_cap_fraction prune_cap_min
      time_zone credentials logger hl_requests_per_10s zoom_requests_per_second
      intelliflo_base_url intelliflo_token_url high_level_base_url zoom_base_url zoom_token_url
      hl_page_limit zoom_page_size country_code_map snapshot_max_age_hours
    ].freeze

    attr_accessor(*SETTINGS)

    DEFAULT_TYPE_MAP = {
      "Staff" => "team_member",
      "Prospect" => "lead",
      "New Financial Planning" => "customer",
      "Financial Planning" => "customer",
      "Investment" => "investment_client",
      "Transactional" => "past_client",
      "Lead - Closed" => "lead",
      "Lead - Initial" => "hot_lead"
    }.freeze

    def initialize
      @hl_location_id = nil
      @hl_custom_field_ids = {}
      # HL "Client Ref" field ("<tenant>-<io id>", written by an earlier
      # integration). Read only, never written; used to report HL contacts whose
      # IO record is no longer listed. Kept out of hl_custom_field_ids so it is
      # not treated as owned.
      @hl_client_ref_field_id = nil
      # Records with a service status outside this list are never created in HL.
      # This is also the only rule that keeps dependants, relatives and corporate
      # records out of HL: none of their statuses appear here.
      @hl_service_status_allowlist = DEFAULT_TYPE_MAP.keys.dup
      @hl_type_map = DEFAULT_TYPE_MAP.dup
      # :keep_current keeps the HL type for linked records whose status is not in
      # the map. Set to a string (the old app used "???") to push that instead.
      @hl_type_fallback = :keep_current
      @hl_default_source = "Wealthwide's CRM System"
      # Linked contacts whose IO service status is in this list get every HL DND
      # channel switched on. "Restricted Processing" is how IO marks a GDPR
      # restriction; there is no separate flag on the record.
      @hl_dnd_statuses = [ "Deceased", "Restricted Processing" ]
      @zoom_exclude_statuses = [ "Deceased" ]
      @zoom_include_leads = false
      @mail_to = nil
      # Plain-English summary (changes, DND, oddities) for the business. Optional.
      @summary_mail_to = nil
      @mail_from = nil
      @writes_enabled = false
      @io_concurrency = 4
      @io_requests_per_second = 8
      @io_failure_threshold = 0.02
      @prune_cap_fraction = 0.1
      @prune_cap_min = 10
      @time_zone = "Europe/London"
      @credentials = nil
      @logger = nil
      @hl_requests_per_10s = 90
      @zoom_requests_per_second = 5
      @intelliflo_base_url = "https://api.gb.intelliflo.net/v2/"
      @intelliflo_token_url = "https://identity.intelliflo.com/core/connect/token"
      @high_level_base_url = "https://services.leadconnectorhq.com/"
      @zoom_base_url = "https://api.zoom.us/v2/"
      @zoom_token_url = "https://zoom.us/oauth/token"
      @hl_page_limit = 500
      @zoom_page_size = 300
      # Intelliflo uses placeholder codes for the UK nations; HighLevel wants ISO 3166-1.
      # The old app sent nil for XW (Wales) and passed anything else through.
      @country_code_map = { "XW" => "GB", "XN" => "GB", "XS" => "GB", "XE" => "GB" }
      # An apply from a snapshot refuses Intelliflo data older than this.
      @snapshot_max_age_hours = 24
    end

    REQUIRED_CUSTOM_FIELDS = %i[courtesy_title salutation category service_status adviser customer_crm].freeze

    def validate!
      missing = []
      missing << "hl_location_id" if hl_location_id.to_s.empty?
      REQUIRED_CUSTOM_FIELDS.each do |key|
        missing << "hl_custom_field_ids[:#{key}]" if hl_custom_field_ids[key].to_s.empty?
      end
      missing << "mail_to" if mail_to.to_s.empty?
      %i[intelliflo high_level zoom].each do |service|
        creds = credentials_for(service)
        required_credentials(service).each do |k|
          missing << "credentials.#{service}.#{k}" if creds[k].to_s.empty?
        end
      end
      raise Error, "IoSync configuration is incomplete: #{missing.join(', ')}" if missing.any?
      true
    end

    # credentials may be a Hash, anything responding to #[] / #dig (Rails
    # credentials), or a lambda returning one of those.
    def credentials_for(service)
      source = credentials.respond_to?(:call) ? credentials.call : credentials
      section = source.respond_to?(:[]) ? (source[service] || source[service.to_s]) : nil
      return {} if section.nil?
      section = section.to_h if section.respond_to?(:to_h)
      section.transform_keys(&:to_sym)
    end

    def required_credentials(service)
      case service
      when :intelliflo then %i[tenant_id api_key client_id client_secret]
      when :high_level then %i[private_integration_token]
      when :zoom then %i[account_id client_id client_secret]
      end
    end

    def owned_custom_field_ids
      hl_custom_field_ids.values
    end

    def logger
      @logger || (defined?(Rails) && Rails.logger) || Logger.new($stdout)
    end
  end
end
