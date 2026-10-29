require "spec_helper"
require "io_sync"
require_relative "../support/builders"

RSpec.describe IoSync::ZoomMapper do
  let(:registry) { IoSync::NumberRegistry.new }

  def mapper(rec, cfg: config, owner: "io:#{rec.io_id}")
    described_class.new(rec, config: cfg, registry: registry, owner: owner)
  end

  it "does not diff an email IO no longer has, since Zoom ignores a null" do
    m = mapper(record(id: 1, contactdetails: contactdetails(email: nil)))
    expect(m.diff(zoom_contact(external_id: "Z", io_id: 1))).to eq({})
  end

  it "builds the payload with the IO id and name string" do
    m = mapper(record(id: 7))
    expect(m.payload).to eq("name" => "Jordan Avery | Kerry/Robin | Financial Planning", "email" => "jordan@example.test", "id" => "7",
                            "description" => "Kerry/Robin | Financial Planning", "phone_numbers" => [ "+447911123456" ])
    expect(m.diff(zoom_contact(external_id: "Z", io_id: 7))).to eq({})
  end

  it "marks vulnerable clients and strips BLANK" do
    expect(mapper(record(id: 1, vulnerability: { "hasVulnerability" => "Yes" })).name_string).to eq("*V* Jordan Avery | Kerry/Robin | Financial Planning *V*")
    r = record(id: 2, details: { first: "BLANK", last: "Kilroy", adviser: nil }, admin: nil)
    expect(mapper(r).name_string).to eq("Kilroy | Financial Planning")
  end

  it "applies eligibility rules" do
    expect(mapper(record(id: 1))).to be_status_eligible
    expect(mapper(record(id: 2, type: :lead))).not_to be_status_eligible
    expect(mapper(record(id: 3, details: { status: "Deceased" }))).not_to be_status_eligible
    expect(mapper(record(id: 4, details: { status: nil }))).not_to be_status_eligible
    expect(mapper(record(id: 5, details: { party: "Corporate" }))).not_to be_status_eligible
  end

  it "does not claim numbers already held by another Zoom contact" do
    registry.seed("+447911123456", "OTHER")
    m = mapper(record(id: 1, contactdetails: contactdetails(mobile: "07911 123 456", telephone: "0121 496 0001")))
    expect(m.claimable_numbers).to eq([ "+441214960001" ])
    expect(m.blocked_numbers).to eq([ "+447911123456" ])
    own = mapper(record(id: 2), owner: "OTHER")
    expect(own.claimable_numbers).to eq([ "+447911123456" ])
  end
end
