require "spec_helper"
require "io_sync"
require "tmpdir"
require_relative "../support/builders"

RSpec.describe IoSync::Snapshot do
  let(:snap) do
    snapshot(records: [ record(id: 1), record(id: 2, details: { first: "Taylor", last: "Brooks" },
                                              contactdetails: contactdetails(email: "taylor@example.test")) ],
             hl: [ hl_contact(id: "A"), hl_contact(id: "B", email: "taylor@example.test", first: "Taylor", last: "Brooks"),
                   hl_contact(id: "R", email: "riley@example.test", first: "Riley", last: "Hart") ],
             zoom: [ zoom_contact(external_id: "Z1", io_id: 1) ],
             links: [ link(io_id: 1, hl: "A", zoom: "Z1"), link(io_id: 2, hl: "B"), link(io_id: 9, hl: "R") ],
             custom_field_names: { "cfCrm" => "Customer CRM" }).tap { |s| s.stats = { io_persons: 2 } }
  end

  it "round-trips through a JSON file, plans identically, and is owner-read-only" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snap.json")
      snap.save(path)
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      back = described_class.load_file(path)
      expect(back.io_listed_ids).to eq(snap.io_listed_ids)
      expect(back.stats[:io_persons]).to eq(2)
      expect(back.links[2].hl_contact_id).to eq("B")
      expect(run_planners(back).actions.map(&:digest)).to eq(run_planners(snap).actions.map(&:digest))
    end
  end

  it "finds IO, link, HL and Zoom together, and HL contacts whose IO record is no longer listed" do
    sam = snap.find("brooks")
    expect(sam.size).to eq(1)
    expect(sam.first[:io].io_id).to eq(2)
    expect(sam.first[:hl]["id"]).to eq("B")

    paul = snap.find("Z1").first
    expect([ paul[:io].io_id, paul[:hl]["id"], paul[:zoom]["external_contact_id"] ]).to eq([ 1, "A", "Z1" ])

    rosalyn = snap.find("riley hart").first
    expect(rosalyn[:io]).to be_nil
    expect(rosalyn[:link].io_id).to eq(9)
    expect(rosalyn[:hl]["id"]).to eq("R")
  end
end
