# Synthetic upstream payloads in the shapes the three APIs really return.
module Builders
  module_function

  def config(**overrides)
    IoSync::Configuration.new.tap do |c|
      c.hl_location_id = "LOC123"
      c.hl_custom_field_ids = { courtesy_title: "cfTitle", salutation: "cfSal", category: "cfCat",
                                service_status: "cfStatus", adviser: "cfAdv", customer_crm: "cfCrm" }
      c.mail_to = "ops@example.test"
      c.mail_from = "noreply@example.test"
      c.credentials = {
        intelliflo: { tenant_id: "t1", api_key: "iokey", client_id: "ioid", client_secret: "iosecret" },
        high_level: { private_integration_token: "pit-test" },
        zoom: { account_id: "acc", client_id: "zid", client_secret: "zsecret" }
      }
      c.io_concurrency = 2
      c.io_requests_per_second = 1000
      c.hl_requests_per_10s = 10_000
      c.zoom_requests_per_second = 1000
      c.logger = Logger.new(File::NULL)
      overrides.each { |k, v| c.public_send("#{k}=", v) }
    end
  end

  def io_details(id:, type: "Client", status: "Financial Planning", first: "Jordan", last: "Avery", salutation: nil, title: "Mr",
                 dob: "1970-01-15", adviser: "Robin Shaw - Example Advisers", admin_id: 900001, segment: "Not Dentist", party: "Person",
                 lead_status: nil)
    d = {
      "id" => id, "name" => "#{first} #{last}", "type" => type, "partyType" => party,
      "person" => { "firstName" => first, "lastName" => last, "salutation" => salutation, "title" => title, "dateOfBirth" => dob },
      "currentAdviser" => adviser && { "id" => 1, "name" => adviser },
      "servicingAdministrator" => admin_id && { "id" => admin_id },
      "clientSegment" => segment && { "name" => segment }
    }
    if type == "Lead"
      d["status"] = lead_status || "Initial"
    else
      d["serviceStatus"] = status && { "name" => status }
    end
    d
  end

  def contactdetails(email: "jordan@example.test", mobile: "07911 123 456", telephone: nil, extra_emails: [], extra_mobiles: [])
    items = []
    items << { "type" => "Email", "value" => email, "isDefault" => true } if email
    extra_emails.each { |e| items << { "type" => "Email", "value" => e, "isDefault" => false } }
    items << { "type" => "Mobile", "value" => mobile, "isDefault" => true } if mobile
    extra_mobiles.each { |m| items << { "type" => "Mobile", "value" => m, "isDefault" => false } }
    items << { "type" => "Telephone", "value" => telephone, "isDefault" => true } if telephone
    items
  end

  def addresses(line1: "12 Sample Road", locality: "Testbury", line2: "", county: "West Midlands", postcode: "ZZ1 1ZZ", country: "GB")
    [ { "type" => "Home", "isDefault" => true, "address" => {
      "line1" => line1, "line2" => line2, "locality" => locality, "postalCode" => postcode,
      "county" => county && { "code" => "GB-073", "name" => county }, "country" => { "code" => country, "name" => "x" } } } ]
  end

  def plans(*providers, status: "In Force")
    providers.map { |p| { "currentStatus" => status, "productProvider" => { "name" => p } } }
  end

  def record(id:, type: :client, details: {}, contactdetails: Builders.contactdetails, addresses: Builders.addresses, plans: [], vulnerability: nil, admin: "Kerry")
    IoSync::IoRecord.new(details: io_details(id: id, type: type == :lead ? "Lead" : "Client", **details), type: type,
                         contactdetails: contactdetails, addresses: addresses, plans: plans, vulnerability: vulnerability, admin_first_name: admin)
  end

  def hl_contact(id:, email: "jordan@example.test", first: "Jordan", last: "Avery", phone: "+447911123456", type: "customer",
                 source: "Wealthwide's CRM System", custom_fields: nil, tags: [], dnd: nil, dob: "1970-01-15", address1: "12 Sample Road",
                 city: "Testbury", state: "West Midlands", postal: "ZZ1 1ZZ", country: "GB", additional: [])
    {
      "id" => id, "email" => email, "firstName" => first, "lastName" => last, "phone" => phone, "type" => type, "source" => source,
      "dateOfBirth" => dob, "address1" => address1, "city" => city, "state" => state, "postalCode" => postal, "country" => country,
      "additionalPhones" => additional, "tags" => tags,
      "customFields" => custom_fields || [ { "id" => "cfTitle", "value" => "Mr" }, { "id" => "cfSal", "value" => first },
                                           { "id" => "cfCat", "value" => "Not Dentist" }, { "id" => "cfStatus", "value" => "Financial Planning" },
                                           { "id" => "cfAdv", "value" => "Robin" }, { "id" => "cfCrm", "value" => "Kerry" } ],
      "dndSettings" => dnd
    }
  end

  def zoom_contact(external_id:, io_id:, name: "Jordan Avery | Kerry/Robin | Financial Planning", email: "jordan@example.test",
                   numbers: [ "+447911123456" ], description: "Kerry/Robin | Financial Planning")
    { "external_contact_id" => external_id, "id" => io_id.to_s, "name" => name, "email" => email,
      "description" => description, "phone_numbers" => numbers, "routing_path" => "PSTN" }
  end

  def link(io_id:, io_type: "client", hl: nil, zoom: nil)
    IoSync::LinkRow.new(io_id: io_id, io_type: io_type, hl_contact_id: hl, zoom_external_contact_id: zoom)
  end

  def snapshot(records: [], hl: [], zoom: [], links: [], listed: nil, custom_field_names: {})
    IoSync::Snapshot.new.tap do |s|
      s.io_records = records.sort_by(&:io_id)
      s.hl_contacts = hl
      s.zoom_contacts = zoom
      s.links = links.to_h { |l| [ l.io_id, l ] }
      s.custom_field_names = custom_field_names
      listed ||= { client: records.select(&:client?).map(&:io_id), lead: records.select(&:lead?).map(&:io_id) }
      s.io_listed_ids = { client: listed[:client].to_set, lead: listed[:lead].to_set }
    end
  end

  def run_planners(snapshot, config: Builders.config, time: Time.utc(2026, 10, 28, 4, 0, 0))
    plan = IoSync::Plan.new
    links = IoSync::Planners::Links.new(snapshot, config: config, plan: plan).call
    IoSync::Planners::HighLevel.new(snapshot, config: config, plan: plan, links: links, time: time).call
    IoSync::Planners::Zoom.new(snapshot, config: config, plan: plan, links: links).call
    plan
  end
end

RSpec.configure { |c| c.include Builders }
