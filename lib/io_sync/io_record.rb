module IoSync
  # Value object over the raw hashes Intelliflo returns. No persistence. All
  # field rules from the old IoClient / IoHl / IoZoom live here.
  class IoRecord
    EMAIL_REGEXP = URI::MailTo::EMAIL_REGEXP

    attr_reader :details, :type
    attr_accessor :contactdetails, :addresses, :plans, :vulnerability, :admin_first_name, :fetch_error

    def initialize(details:, type:, contactdetails: nil, addresses: nil, plans: nil, vulnerability: nil, admin_first_name: nil)
      @details = details || {}
      @type = type.to_sym
      @contactdetails = contactdetails
      @addresses = addresses
      @plans = plans
      @vulnerability = vulnerability
      @admin_first_name = admin_first_name
      @fetch_error = nil
    end

    def to_h
      { "type" => type.to_s, "details" => details, "contactdetails" => contactdetails, "addresses" => addresses,
        "plans" => plans, "vulnerability" => vulnerability, "admin_first_name" => admin_first_name, "fetch_error" => fetch_error }
    end

    def self.from_h(h)
      new(details: h["details"], type: h["type"], contactdetails: h["contactdetails"], addresses: h["addresses"], plans: h["plans"],
          vulnerability: h["vulnerability"], admin_first_name: h["admin_first_name"]).tap { |r| r.fetch_error = h["fetch_error"] }
    end

    def io_id = details["id"]
    def lead? = type == :lead
    def client? = type == :client
    def person? = details["partyType"] == "Person"
    def name = details["name"].to_s
    def person = details["person"] || {}
    def first_name = person["firstName"]
    def last_name = person["lastName"]
    def salutation = person["salutation"]
    def title = person["title"]
    def date_of_birth = person["dateOfBirth"]
    def category = details.dig("clientSegment", "name")
    def servicing_administrator_id = details.dig("servicingAdministrator", "id")

    def service_status
      details.dig("serviceStatus", "name").then { |s| s.to_s.strip.empty? ? nil : s } ||
        "#{details['type']} - #{details['status']}"
    end

    def service_status_present? = !details.dig("serviceStatus", "name").to_s.strip.empty?
    def deceased? = service_status == "Deceased"

    def adviser_name = details.dig("currentAdviser", "name")

    def adviser_first_name
      first = adviser_name.to_s.split(" ").first
      first.nil? || first == "No" ? nil : first
    end

    def admin_first_name_clean
      v = admin_first_name.to_s.strip
      v.empty? ? nil : v
    end

    # The default email, stripped and downcased, only if it looks like an email.
    def email
      detail = email_details.detect { |c| c["isDefault"] == true }
      value = detail && detail["value"].to_s.strip.downcase
      value if value && value.match?(EMAIL_REGEXP)
    end

    def emails
      email_details.map { |c| c["value"].to_s.strip.downcase }.reject(&:empty?)
    end

    def has_email?(address)
      emails.include?(address.to_s.downcase)
    end

    # Ordered candidates: default mobile, other mobiles, default telephone,
    # other telephones (raw values).
    def phone_candidates
      phones = Array(contactdetails).select { |c| %w[Mobile Telephone].include?(c["type"]) }
      mobiles = phones.select { |c| c["type"] == "Mobile" }
      tels = phones.select { |c| c["type"] == "Telephone" }
      order = ->(list) { list.partition { |c| c["isDefault"] == true }.flatten }
      (order.call(mobiles) + order.call(tels)).map { |c| c["value"] }
    end

    def numbers
      phone_candidates.map { |v| Phone.normalise(v) }.compact.uniq
    end

    def phone = numbers.first

    def additional_phones
      numbers.drop(1).map { |n| { "phone" => n, "phoneLabel" => nil } }
    end

    def home_address(country_code_map: { "XW" => nil })
      address = Array(addresses).detect { |a| a["type"] == "Home" && a["isDefault"] == true }
      return {} unless address && address["address"]
      a = address["address"]
      country = a.dig("country", "code")
      country = country_code_map[country] if country && country_code_map.key?(country)
      {
        "line1" => presence(a["line1"]),
        "city" => presence(a["locality"]) || presence(a["line2"]),
        "county" => a.dig("county", "name"),
        "postalCode" => presence(a["postalCode"]),
        "country" => presence(country)
      }
    end

    def plan_tags
      Array(plans).select { |p| p["currentStatus"].to_s.downcase == "in force" }
                  .map { |p| "plan - #{p.dig('productProvider', 'name')}".downcase.strip }
                  .uniq
    end

    def vulnerable?
      vulnerability.is_a?(Hash) && vulnerability["hasVulnerability"] == "Yes"
    end

    def allowlisted?(config)
      config.hl_service_status_allowlist.include?(service_status)
    end

    def label
      "#{name.empty? ? [first_name, last_name].compact.join(' ') : name} (IO #{io_id})"
    end

    private

    def email_details
      Array(contactdetails).select { |c| c["type"] == "Email" }
    end

    def presence(value)
      v = value.to_s.strip
      v.empty? ? nil : v
    end
  end
end
