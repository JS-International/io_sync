require "spec_helper"
require "io_sync"
require_relative "../support/builders"

RSpec.describe IoSync::IoRecord do
  it "takes the default email, downcased, only when valid" do
    r = record(id: 1, contactdetails: contactdetails(email: " Jordan.Avery@Example.TEST ", extra_emails: [ "old@example.test" ]))
    expect(r.email).to eq("jordan.avery@example.test")
    expect(r.has_email?("OLD@example.test")).to be(true)
    expect(record(id: 2, contactdetails: contactdetails(email: "not an email")).email).to be_nil
    expect(record(id: 3, contactdetails: [ { "type" => "Email", "value" => "x@example.test", "isDefault" => false } ]).email).to be_nil
  end

  it "derives service status for leads from type and status" do
    expect(record(id: 1, type: :lead, details: { lead_status: "Closed" }).service_status).to eq("Lead - Closed")
    expect(record(id: 1, type: :lead).service_status_present?).to be(false)
    expect(record(id: 2, details: { status: "Deceased" })).to be_deceased
  end

  it "orders phone candidates default mobile, other mobiles, default telephone, other telephones" do
    r = record(id: 1, contactdetails: contactdetails(mobile: "07911 123 456", telephone: "0121 496 0001", extra_mobiles: [ "07911 123 457" ]))
    expect(r.numbers).to eq([ "+447911123456", "+447911123457", "+441214960001" ])
    expect(r.phone).to eq("+447911123456")
    expect(r.additional_phones).to eq([ { "phone" => "+447911123457", "phoneLabel" => nil }, { "phone" => "+441214960001", "phoneLabel" => nil } ])
  end

  it "falls back past an invalid default mobile" do
    r = record(id: 1, contactdetails: contactdetails(mobile: "07911 123 459 (NOT VALID)", telephone: "0121 496 0001"))
    expect(r.phone).to eq("+441214960001")
  end

  it "builds the home address and drops the Wales placeholder country" do
    expect(record(id: 1).home_address).to eq("line1" => "12 Sample Road", "city" => "Testbury", "county" => "West Midlands",
                                              "postalCode" => "ZZ1 1ZZ", "country" => "GB")
    r = record(id: 2, addresses: addresses(locality: "", line2: "Harbourne", country: "XW"))
    expect(r.home_address["city"]).to eq("Harbourne")
    expect(r.home_address["country"]).to be_nil
    expect(r.home_address(country_code_map: { "XW" => "GB" })["country"]).to eq("GB")
    expect(record(id: 3, addresses: addresses(country: "XN")).home_address(country_code_map: IoSync::Configuration.new.country_code_map)["country"]).to eq("GB")
    expect(record(id: 3, addresses: nil).home_address).to eq({})
  end

  it "maps adviser, admin, category and plan tags" do
    r = record(id: 1, plans: plans("Aviva ", "Scottish Widows") + plans("Old", status: "Lapsed"))
    expect(r.adviser_first_name).to eq("Robin")
    expect(record(id: 2, details: { adviser: "No Adviser" }).adviser_first_name).to be_nil
    expect(record(id: 3, admin: "  ").admin_first_name_clean).to be_nil
    expect(r.plan_tags).to eq([ "plan - aviva", "plan - scottish widows" ])
    expect(r.category).to eq("Not Dentist")
    expect(record(id: 4, vulnerability: { "hasVulnerability" => "Yes" })).to be_vulnerable
  end
end
