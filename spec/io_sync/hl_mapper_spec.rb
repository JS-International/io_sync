require "spec_helper"
require "io_sync"
require_relative "../support/builders"

RSpec.describe IoSync::HlMapper do
  let(:cfg) { config }

  it "builds the full payload for a new contact" do
    payload = described_class.new(record(id: 1, details: { salutation: " Jordie " }), config: cfg).payload
    expect(payload).to include("firstName" => "Jordie", "lastName" => "Avery", "email" => "jordan@example.test", "dateOfBirth" => "1970-01-15",
                               "phone" => "+447911123456", "additionalPhones" => [], "address1" => "12 Sample Road", "city" => "Testbury",
                               "country" => "GB", "state" => "West Midlands", "postalCode" => "ZZ1 1ZZ", "type" => "customer",
                               "source" => "Wealthwide's CRM System")
    expect(payload["customFields"]).to contain_exactly(
      { "id" => "cfTitle", "value" => "Mr" }, { "id" => "cfSal", "value" => "Jordie" }, { "id" => "cfCat", "value" => "Not Dentist" },
      { "id" => "cfStatus", "value" => "Financial Planning" }, { "id" => "cfAdv", "value" => "Robin" }, { "id" => "cfCrm", "value" => "Kerry" })
  end

  it "does not diff what HL will not clear: an empty country, or an owned field left out of the payload" do
    rec = record(id: 1, details: { title: nil }, addresses: addresses(country: nil))
    m = described_class.new(rec, config: cfg, current: hl_contact(id: "A"))
    expect(m.payload["country"]).to be_nil
    expect(m.diff).to eq({})
    no_adviser = record(id: 1, details: { adviser: nil })
    expect(described_class.new(no_adviser, config: cfg, current: hl_contact(id: "A")).diff).to eq("customFields.cfAdv" => [ "Robin", nil ])
  end

  it "is up to date when the live contact matches" do
    m = described_class.new(record(id: 1), config: cfg, current: hl_contact(id: "A"))
    expect(m.diff).to eq({})
    expect(m).to be_up_to_date
  end

  it "reports field level differences, naming custom fields" do
    current = hl_contact(id: "A", phone: "+447000000000", email: "old@example.test", dob: "1970-01-15T00:00:00.000Z")
    m = described_class.new(record(id: 1), config: cfg, current: current, custom_field_names: { "cfCrm" => "Customer CRM" })
    expect(m.diff.keys).to contain_exactly("phone", "email")
    expect(described_class.new(record(id: 1, details: { dob: "1967-12-01" }), config: cfg, current: hl_contact(id: "A", dob: -65836800000)).diff).to eq({})
    current["customFields"].reject! { |cf| cf["id"] == "cfCrm" }
    m = described_class.new(record(id: 1), config: cfg, current: current, custom_field_names: { "cfCrm" => "Customer CRM" })
    expect(m.diff["customFields.Customer CRM"]).to eq([ nil, "Kerry" ])
  end

  it "keeps the HL source, type and foreign custom fields" do
    current = hl_contact(id: "A", source: "LinkedIn", type: "lead", custom_fields: [ { "id" => "other", "value" => "keep me" } ])
    m = described_class.new(record(id: 1, details: { status: "Dependant Child/Grandchild" }), config: cfg, current: current)
    expect(m.payload["source"]).to eq("LinkedIn")
    expect(m.payload["type"]).to eq("lead")
    expect(m.payload["customFields"]).to include({ "id" => "other", "value" => "keep me" })
    m2 = described_class.new(record(id: 1, details: { status: "Dependant Child/Grandchild" }), config: config(hl_type_fallback: "???"), current: current)
    expect(m2.payload["type"]).to eq("???")
  end

  it "clears adviser and admin only when HL holds the field, and keeps HL category when IO has none" do
    current = hl_contact(id: "A")
    m = described_class.new(record(id: 1, details: { adviser: "No Adviser", segment: nil }, admin: nil), config: cfg, current: current)
    cfs = m.payload["customFields"]
    expect(cfs).to include({ "id" => "cfAdv", "value" => nil }, { "id" => "cfCrm", "value" => nil }, { "id" => "cfCat", "value" => "Not Dentist" })
    m2 = described_class.new(record(id: 1, details: { adviser: "No Adviser", segment: nil }, admin: nil), config: cfg)
    expect(m2.payload["customFields"].map { |cf| cf["id"] }).not_to include("cfAdv", "cfCrm", "cfCat")
  end

  it "computes plan tag changes and dnd needs" do
    current = hl_contact(id: "A", tags: [ "plan - old co", "imported 2024", "plan - aviva" ])
    m = described_class.new(record(id: 1, plans: plans("Aviva", "Fundment")), config: cfg, current: current)
    expect(m.tags_to_add).to eq([ "plan - fundment" ])
    expect(m.tags_to_remove).to eq([ "plan - old co" ])
    expect(m.dnd_needed?).to be(true)
    all_active = described_class::DND_CHANNELS.to_h { |c| [ c, { "status" => "active" } ] }
    expect(described_class.new(record(id: 1), config: cfg, current: hl_contact(id: "A", dnd: all_active)).dnd_needed?).to be(false)
    expect(m.dnd_payload("t")["WhatsApp"]).to eq("status" => "active", "message" => "Updated by Intelliflo t")
  end
end
