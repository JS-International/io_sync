require "spec_helper"
require "io_sync"
require_relative "../support/builders"

RSpec.describe "IoSync planners" do
  def actions(plan, target, kind = nil)
    plan.actions.select { |a| a.target == target && (kind.nil? || a.kind == kind) }
  end

  it "creates an HL contact and a Zoom contact for an allowlisted, unlinked client" do
    plan = run_planners(snapshot(records: [ record(id: 1) ]))
    create = actions(plan, :hl, :create).first
    expect(create.payload["email"]).to eq("jordan@example.test")
    expect(create.diff).to eq("(new)" => [ nil, "create" ])
    expect(actions(plan, :zoom, :create).first.payload["id"]).to eq("1")
    expect(actions(plan, :hl, :add_tags)).to be_empty
    expect(plan.problems).to be_empty
  end

  it "plans noops for linked, up-to-date records" do
    s = snapshot(records: [ record(id: 1) ], hl: [ hl_contact(id: "A") ], zoom: [ zoom_contact(external_id: "Z", io_id: 1) ],
                 links: [ link(io_id: 1, hl: "A", zoom: "Z") ])
    plan = run_planners(s)
    expect(plan.actions.map { |a| [ a.target, a.kind ] }).to contain_exactly([ :hl, :noop ], [ :zoom, :noop ])
  end

  it "plans updates with diffs" do
    s = snapshot(records: [ record(id: 1) ], hl: [ hl_contact(id: "A", phone: "+447000000000") ],
                 zoom: [ zoom_contact(external_id: "Z", io_id: 1, numbers: [ "+447000000000" ]) ], links: [ link(io_id: 1, hl: "A", zoom: "Z") ])
    plan = run_planners(s)
    expect(actions(plan, :hl, :update).first.diff.keys).to eq([ "phone" ])
    expect(actions(plan, :zoom, :update).first.diff.keys).to eq([ "phone_numbers" ])
  end

  it "ignores records outside the allowlist unless linked" do
    plan = run_planners(snapshot(records: [ record(id: 1, details: { status: "Dependant Child/Grandchild" }) ]))
    expect(actions(plan, :hl)).to be_empty
    s = snapshot(records: [ record(id: 1, details: { status: "Ex Client" }) ], hl: [ hl_contact(id: "A", type: "past_client") ],
                 links: [ link(io_id: 1, hl: "A") ])
    update = actions(run_planners(s), :hl, :update).first
    expect(update.payload["type"]).to eq("past_client")
    expect(update.diff.keys).to eq([ "customFields.cfStatus" ])
  end

  it "skips a lead whose email belongs to a contact linked to another record, and reports other conflicts" do
    client = record(id: 10)
    lead = record(id: 11, type: :lead, details: { lead_status: "Closed" })
    s = snapshot(records: [ client, lead ], hl: [ hl_contact(id: "A") ], links: [ link(io_id: 10, hl: "A") ])
    plan = run_planners(s)
    expect(actions(plan, :hl, :skip).map(&:io_id)).to eq([ 11 ])
    expect(plan.problems).to be_empty

    other = record(id: 12, details: { first: "Morgan" })
    plan = run_planners(snapshot(records: [ client, other ], hl: [ hl_contact(id: "A") ], links: [ link(io_id: 10, hl: "A") ]))
    conflict = actions(plan, :hl, :conflict).first
    expect(conflict.io_id).to eq(12)
    expect(conflict.reason).to include("Two IO records share this email")

    moved = record(id: 10, contactdetails: contactdetails(email: "new@example.test", extra_emails: [ "jordan@example.test" ]))
    plan = run_planners(snapshot(records: [ moved ], hl: [ hl_contact(id: "A"), hl_contact(id: "B", email: "new@example.test") ],
                                 links: [ link(io_id: 10, hl: "A") ]))
    conflict = actions(plan, :hl, :conflict).first
    expect(conflict.reason).to include("not linked to any IO record", "Merge or delete the duplicate in HL")
  end

  it "relinks a converted lead's contact to the client" do
    client = record(id: 10)
    lead = record(id: 11, type: :lead, details: { lead_status: "Closed" })
    s = snapshot(records: [ client, lead ], hl: [ hl_contact(id: "A", type: "hot_lead") ], links: [ link(io_id: 11, io_type: "lead", hl: "A") ])
    plan = run_planners(s)
    relink = actions(plan, :link, :relink).first
    expect(relink.payload).to eq("from_io_id" => 11, "to_io_id" => 10, "hl_contact_id" => "A")
    expect(actions(plan, :hl, :update).first.io_id).to eq(10)
    expect(actions(plan, :hl, :skip).first.io_id).to eq(11)
  end

  it "relinks when the linked record lost its email and one other record holds it" do
    hugh = record(id: 20, details: { first: "Hugh" }, contactdetails: contactdetails(email: nil))
    hilary = record(id: 21, details: { first: "Hilary" })
    s = snapshot(records: [ hugh, hilary ], hl: [ hl_contact(id: "A", first: "Hilary") ], links: [ link(io_id: 20, hl: "A") ])
    plan = run_planners(s)
    expect(actions(plan, :link, :relink).first.payload["to_io_id"]).to eq(21)
    expect(actions(plan, :hl).map { |a| [ a.io_id, a.kind ] }).to eq([ [ 21, :noop ] ])
  end

  it "keeps the link when a record merely changed its email" do
    moved = record(id: 10, contactdetails: contactdetails(email: "new@example.test", extra_emails: [ "jordan@example.test" ]))
    plan = run_planners(snapshot(records: [ moved ], hl: [ hl_contact(id: "A") ], links: [ link(io_id: 10, hl: "A") ]))
    expect(actions(plan, :link)).to be_empty
    expect(actions(plan, :hl, :update).first.diff["email"]).to eq([ "jordan@example.test", "new@example.test" ])
  end

  it "links unlinked HL contacts by email, preferring clients and reporting ambiguity" do
    client = record(id: 10)
    lead = record(id: 11, type: :lead)
    plan = run_planners(snapshot(records: [ client, lead ], hl: [ hl_contact(id: "A") ]))
    expect(actions(plan, :link, :link).map { |a| [ a.io_id, a.remote_id ] }).to eq([ [ 10, "A" ] ])
    expect(actions(plan, :hl).map { |a| [ a.io_id, a.kind ] }).to contain_exactly([ 10, :noop ], [ 11, :skip ])

    twins = [ record(id: 10), record(id: 12, details: { first: "Twin" }) ]
    plan = run_planners(snapshot(records: twins, hl: [ hl_contact(id: "A") ]))
    expect(actions(plan, :link)).to be_empty
    expect(plan.problems.first).to include("matches several IO records")
  end

  it "unlinks records missing from the IO list within the cap, and reports when over it" do
    rows = (1..5).map { |i| link(io_id: i, hl: "H#{i}", zoom: "Z#{i}") }
    hl = (1..5).map { |i| hl_contact(id: "H#{i}", email: "p#{i}@example.test") }
    zoom = (1..5).map { |i| zoom_contact(external_id: "Z#{i}", io_id: i) }
    s = snapshot(records: [ record(id: 1, contactdetails: contactdetails(email: "p1@example.test")) ], hl: hl, zoom: zoom, links: rows,
                 listed: { client: [ 1, 2, 3, 4 ], lead: [] })
    plan = run_planners(s, config: config(prune_cap_min: 1))
    expect(actions(plan, :link, :unlink).map(&:io_id)).to eq([ 5 ])
    expect(actions(plan, :zoom, :delete).map(&:remote_id)).to eq([ "Z5" ])

    s = snapshot(records: [ record(id: 1, contactdetails: contactdetails(email: "p1@example.test")) ], hl: hl, zoom: zoom, links: rows,
                 listed: { client: [ 1 ], lead: [] })
    plan = run_planners(s, config: config(prune_cap_min: 1))
    expect(actions(plan, :link, :unlink)).to be_empty
    expect(actions(plan, :link, :prune_skipped).size).to eq(4)
    expect(plan.problems.first).to include("Skipped unlinking 4 client rows")
  end

  it "drops link ids whose remote records vanished" do
    s = snapshot(records: [ record(id: 1) ], links: [ link(io_id: 1, hl: "GONE", zoom: "GONE") ])
    plan = run_planners(s)
    expect(actions(plan, :link, :unlink).map(&:reason)).to contain_exactly(a_string_including("HL contact GONE"), a_string_including("Zoom contact GONE"))
    expect(actions(plan, :hl, :create).size).to eq(1)
  end

  it "sets DND for deceased linked contacts even without an email, and deletes their Zoom contact" do
    deceased = record(id: 1, details: { status: "Deceased" }, contactdetails: contactdetails(email: nil))
    s = snapshot(records: [ deceased ], hl: [ hl_contact(id: "A", dnd: nil) ], zoom: [ zoom_contact(external_id: "Z", io_id: 1) ],
                 links: [ link(io_id: 1, hl: "A", zoom: "Z") ])
    plan = run_planners(s)
    dnd = actions(plan, :hl, :dnd).first
    expect(dnd.payload["dndSettings"].keys).to eq(%w[Email FB GMB SMS Call WhatsApp])
    expect(dnd.payload["dndSettings"]["Email"]["message"]).to include("Updated by Intelliflo 2026-10-28")
    later = actions(run_planners(s, time: Time.utc(2026, 10, 29, 9, 0, 0)), :hl, :dnd).first
    expect(later.payload).not_to eq(dnd.payload)
    expect(later.digest).to eq(dnd.digest)
    expect(actions(plan, :zoom, :delete).first.remote_id).to eq("Z")
    all_active = IoSync::HlMapper::DND_CHANNELS.to_h { |c| [ c, { "status" => "active" } ] }
    s.hl_contacts = [ hl_contact(id: "A", dnd: all_active) ]
    expect(actions(run_planners(s), :hl, :dnd)).to be_empty
  end

  it "sets DND for restricted-processing linked contacts, and not for other statuses" do
    restricted = record(id: 1, details: { status: "Restricted Processing" })
    s = snapshot(records: [ restricted, record(id: 2, details: { status: "Ex Client" }) ],
                 hl: [ hl_contact(id: "A", dnd: nil), hl_contact(id: "B", email: "other@example.test", dnd: nil) ],
                 links: [ link(io_id: 1, hl: "A"), link(io_id: 2, hl: "B") ])
    dnd = actions(run_planners(s), :hl, :dnd)
    expect(dnd.map(&:remote_id)).to eq([ "A" ])
    expect(dnd.first.reason).to eq("restricted processing")
    expect(actions(run_planners(s, config: config(hl_dnd_statuses: [ "Deceased" ])), :hl, :dnd)).to be_empty
  end

  it "adds and removes plan tags without touching other tags" do
    current = hl_contact(id: "A", tags: [ "plan - old co", "imported 2024" ])
    s = snapshot(records: [ record(id: 1, plans: plans("Aviva")) ], hl: [ current ], links: [ link(io_id: 1, hl: "A") ])
    plan = run_planners(s)
    expect(actions(plan, :hl, :add_tags).first.payload).to eq("tags" => [ "plan - aviva" ])
    expect(actions(plan, :hl, :remove_tags).first.payload).to eq("tags" => [ "plan - old co" ])
    s = snapshot(records: [ record(id: 1, plans: []) ], hl: [ current ], links: [ link(io_id: 1, hl: "A") ])
    expect(actions(run_planners(s), :hl, :remove_tags).first.payload).to eq("tags" => [ "plan - old co" ])
    s = snapshot(records: [ record(id: 1, plans: nil) ], hl: [ current ], links: [ link(io_id: 1, hl: "A") ])
    expect(actions(run_planners(s), :hl, :remove_tags)).to be_empty
  end

  it "skips Zoom when every number is held by another contact, and adopts contacts by IO id" do
    s = snapshot(records: [ record(id: 1) ], zoom: [ zoom_contact(external_id: "OTHER", io_id: 99, numbers: [ "+447911123456" ]) ])
    plan = run_planners(s)
    skip = actions(plan, :zoom, :skip).first
    expect(skip.reason).to include("already on Zoom contact OTHER", "(IO 99)")
    expect(plan.notes[:zoom_number_conflicts].first[:detail]).to start_with("not added to Zoom: +447911123456")

    s = snapshot(records: [ record(id: 1) ], zoom: [ zoom_contact(external_id: "Z", io_id: 1) ])
    plan = run_planners(s)
    expect(actions(plan, :link, :adopt).first.remote_id).to eq("Z")
    expect(actions(plan, :zoom, :noop).size).to eq(1)
  end

  it "never puts the firm's own Zoom numbers on an external contact" do
    s = snapshot(records: [ record(id: 1, contactdetails: contactdetails(mobile: "07911 123 458", telephone: "0121 496 0060")) ])
    s.zoom_account_numbers = [ { "number" => "+441214960060", "assignee" => { "name" => "Main Auto Receptionist" } } ]
    plan = run_planners(s)
    expect(actions(plan, :zoom, :create).first.payload["phone_numbers"]).to eq([ "+447911123458" ])
    expect(plan.notes[:zoom_number_conflicts].first[:detail]).to include("+441214960060 (already on the firm's own Zoom number (Main Auto Receptionist))")
  end

  it "claims numbers first come first served in io_id order" do
    a = record(id: 1)
    b = record(id: 2, details: { first: "Morgan" }, contactdetails: contactdetails(email: "c@example.test"))
    plan = run_planners(snapshot(records: [ b, a ]))
    creates = actions(plan, :zoom, :create)
    expect(creates.map(&:io_id)).to eq([ 1 ])
    expect(actions(plan, :zoom, :skip).first.io_id).to eq(2)
  end

  it "skips records whose Intelliflo fetch failed" do
    r = record(id: 1)
    r.fetch_error = "boom"
    s = snapshot(records: [ r ], hl: [ hl_contact(id: "A") ], links: [ link(io_id: 1, hl: "A") ])
    plan = run_planners(s)
    expect(actions(plan, :hl).map(&:kind)).to eq([ :skip ])
    expect(actions(plan, :zoom).map(&:kind)).to eq([ :skip ])
  end
end
