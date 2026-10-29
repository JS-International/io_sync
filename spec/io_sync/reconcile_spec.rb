require "spec_helper"
require "io_sync"
require "tmpdir"
require_relative "../support/builders"
require_relative "../support/api_stubs"

RSpec.describe IoSync::Reconcile do
  let(:mailer) { double("mailer").tap { |m| allow(m).to receive(:report).and_return(double(deliver_now: true)) } }
  let(:cfg) { config }
  let(:store) { IoSync::MemoryLinkStore.new([ link(io_id: 1, hl: "A", zoom: "Z1") ]) }

  # IO: client 1 (linked, phone changed in HL), client 2 (new), lead 3 (no email), deceased 4 (linked HL only).
  before do
    stub_intelliflo(
      clients: [ io_details(id: 1), io_details(id: 2, first: "Morgan", last: "Hale"), io_details(id: 4, first: "Hugh", status: "Deceased") ],
      leads: [ io_details(id: 3, type: "Lead", first: "Lee") ],
      contactdetails: { 1 => contactdetails, 2 => contactdetails(email: "morgan@example.test", mobile: "07911 123 457"), 3 => contactdetails(email: nil, mobile: nil),
                        4 => contactdetails(email: "hugh@example.test", mobile: nil) },
      addresses: { 1 => addresses, 2 => addresses }, plans: { 1 => plans("Aviva") },
      users: [ { "id" => 900001, "firstName" => "Kerry" } ]
    )
    stub_high_level(contacts: [ hl_contact(id: "A", phone: "+447000000000", tags: [ "plan - old" ]), hl_contact(id: "D", email: "hugh@example.test", first: "Hugh", dnd: nil) ],
                    custom_fields: [ { "id" => "cfCrm", "name" => "Customer CRM" } ])
    stub_zoom(contacts: [ zoom_contact(external_id: "Z1", io_id: 1) ])
  end

  def reconcile(mode:, approved: nil, config: cfg)
    described_class.new(mode: mode, approved: approved, config: config, link_store: store, mailer: mailer, clock: Time).call
  end

  it "plans without writing anything" do
    report = reconcile(mode: :plan)
    expect(report.status).to eq(:planned)
    kinds = report.actions.map { |a| [ a.target, a.kind, a.io_id ] }
    expect(kinds).to include([ :hl, :update, 1 ], [ :hl, :add_tags, 1 ], [ :hl, :remove_tags, 1 ], [ :hl, :create, 2 ], [ :zoom, :noop, 1 ], [ :zoom, :create, 2 ],
                             [ :link, :link, 4 ], [ :hl, :dnd, 4 ])
    expect(report.actions.detect { |a| a.kind == :update }.diff.keys).to eq([ "phone" ])
    expect(report.stats[:io_persons]).to eq(4)
    expect(write_requests).to be_empty
    expect(mailer).to have_received(:report).with(report)
    expect(store.all.size).to eq(1)
  end

  it "also sends the summary when summary_mail_to is set" do
    allow(mailer).to receive(:summary).and_return(double(deliver_now: true))
    report = reconcile(mode: :plan, config: config(summary_mail_to: "summary@example.test"))
    expect(mailer).to have_received(:summary).with(report)
    reconcile(mode: :plan)
    expect(mailer).to have_received(:summary).once
  end

  it "saves a snapshot on the first plan run and replans from it without any requests" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snap.json")
      first = described_class.new(mode: :plan, snapshot: path, config: cfg, link_store: store, mailer: mailer).call
      expect(File).to exist(path)
      WebMock::RequestRegistry.instance.reset!
      second = described_class.new(mode: :plan, snapshot: path, config: cfg, link_store: store, mailer: mailer).call
      expect(WebMock::RequestRegistry.instance.requested_signatures.hash).to be_empty
      expect(second.actions.map(&:digest)).to eq(first.actions.map(&:digest))
      expect(second.stats[:snapshot_from]).to eq(path)
    end
  end

  it "applies from a snapshot using its IO data and live HL and Zoom reads, never Intelliflo" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snap.json")
      described_class.new(mode: :plan, snapshot: path, config: cfg, link_store: store, mailer: mailer).call
      WebMock::RequestRegistry.instance.reset!
      stub_request(:put, "#{ApiStubs::HL}/contacts/A").to_return(json({ contact: hl_contact(id: "A") }))
      stub_request(:any, /#{ApiStubs::HL}|#{ApiStubs::ZOOM}/).with { |r| r.method != :get && !r.uri.path.end_with?("/contacts/search") }
                                                               .to_return(json({ contact: hl_contact(id: "NEW") }, status: 201))

      report = described_class.new(mode: :apply, snapshot: path, config: config(writes_enabled: true), link_store: store, mailer: mailer).call
      expect(report.status).to eq(:applied)
      hosts = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.map { |sig| sig.uri.host }.uniq
      expect(hosts).not_to include(URI(IoSync.config.intelliflo_base_url).host)
      expect(report.stats[:remote_refreshed_at]).not_to be_nil
    end
  end

  it "re-reads only HL and Zoom when a snapshot plan asks to refresh remote" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snap.json")
      described_class.new(mode: :plan, snapshot: path, config: cfg, link_store: store, mailer: mailer).call
      WebMock::RequestRegistry.instance.reset!
      report = described_class.new(mode: :plan, snapshot: path, refresh_remote: true, config: cfg, link_store: store, mailer: mailer).call
      hosts = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.map { |sig| sig.uri.host }.uniq
      expect(hosts).not_to include(URI(IoSync.config.intelliflo_base_url).host)
      expect(hosts).to include(URI(ApiStubs::HL).host, URI(ApiStubs::ZOOM).host)
      expect(report.stats[:remote_refreshed_at]).not_to be_nil
    end
  end

  it "refuses to apply from a missing or stale snapshot before any request" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snap.json")
      expect { described_class.new(mode: :apply, snapshot: path, config: config(writes_enabled: true), link_store: store, mailer: mailer).call }
        .to raise_error(IoSync::Error, /does not exist/)
      File.write(path, JSON.generate("saved_at" => (Time.now - 30 * 3600).utc.iso8601))
      expect { described_class.new(mode: :apply, snapshot: path, config: config(writes_enabled: true), link_store: store, mailer: mailer).call }
        .to raise_error(IoSync::Error, /hours old/)
      expect(WebMock::RequestRegistry.instance.requested_signatures.hash).to be_empty
    end
  end

  it "fails the run, not the boot, when the configuration is incomplete" do
    expect { IoSync.configure(validate: false) { |c| c.mail_to = nil } }.not_to raise_error
    expect { reconcile(mode: :plan, config: config(mail_to: nil)) }.to raise_error(IoSync::Error, /mail_to/)
    expect(WebMock::RequestRegistry.instance.requested_signatures.hash).to be_empty
  ensure
    IoSync.reset_config!
  end

  it "refuses to apply while the kill switch is off, before any request" do
    expect { reconcile(mode: :apply) }.to raise_error(IoSync::WriteDisabled)
    expect(WebMock::RequestRegistry.instance.requested_signatures.hash).to be_empty
  end

  it "applies in order, records results and writes link rows" do
    stub_request(:put, "#{ApiStubs::HL}/contacts/A").to_return(json({ contact: hl_contact(id: "A") }))
    stub_request(:post, "#{ApiStubs::HL}/contacts/").to_return(json({ contact: hl_contact(id: "NEW", email: "morgan@example.test") }))
    stub_request(:post, "#{ApiStubs::HL}/contacts/A/tags").to_return(json({}))
    stub_request(:delete, "#{ApiStubs::HL}/contacts/A/tags").to_return(json({}))
    stub_request(:put, "#{ApiStubs::HL}/contacts/D").to_return(json({ contact: hl_contact(id: "D") }))
    stub_request(:post, "#{ApiStubs::ZOOM}/phone/external_contacts").to_return(json({ external_contact_id: "ZNEW" }, status: 201))

    report = reconcile(mode: :apply, config: config(writes_enabled: true))
    expect(report.status).to eq(:applied)
    expect(report.result_counts).to eq(ok: report.writes.size)
    expect(store.find(2).hl_contact_id).to eq("NEW")
    expect(store.find(2).zoom_external_contact_id).to eq("ZNEW")
    expect(store.find(4).hl_contact_id).to eq("D")
    expect(a_request(:post, "#{ApiStubs::HL}/contacts/").with { |r| JSON.parse(r.body)["locationId"] == "LOC123" }).to have_been_made
    expect(a_request(:put, "#{ApiStubs::HL}/contacts/D").with { |r| JSON.parse(r.body).dig("dndSettings", "SMS", "status") == "active" }).to have_been_made
  end

  it "applies only approved actions and isolates failures" do
    planned = reconcile(mode: :plan)
    approved_digest = planned.actions.detect { |a| a.kind == :update }.digest
    approved = IoSync::Report.from_json(planned.to_json)
    approved.actions = approved.actions.select { |a| a.digest == approved_digest }
    stub_request(:put, "#{ApiStubs::HL}/contacts/A").to_return(json({ message: "boom" }, status: 500))

    report = reconcile(mode: :apply, approved: approved, config: config(writes_enabled: true))
    statuses = report.writes.to_h { |a| [ [ a.kind, a.io_id ], a.result[:status] ] }
    expect(statuses[[ :update, 1 ]]).to eq(:error)
    expect(statuses[[ :create, 2 ]]).to eq(:unapproved)
    expect(report.approved_from).to eq(planned.run_id)
    expect(write_requests.map { |s| s.uri.path }).to eq([ "/contacts/A" ])
  end

  it "aborts and still reports when too many Intelliflo fetches fail" do
    stub_request(:get, "#{ApiStubs::IO}/clients/2/contactdetails").to_return(status: 500, body: "")
    report = reconcile(mode: :plan, config: config(io_failure_threshold: 0.0))
    expect(report.status).to eq(:aborted)
    expect(report.error).to include("failed to load")
    expect(mailer).to have_received(:report)
  end
end
