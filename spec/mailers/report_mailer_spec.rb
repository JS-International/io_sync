require "rails_helper"

RSpec.describe IoSync::ReportMailer, type: :mailer do
  it "renders the summary, problems, diffs and attaches the JSON" do
    IoSync.configure { |c| Builders.config.instance_variables.each { |iv| c.instance_variable_set(iv, Builders.config.instance_variable_get(iv)) } }
    plan = Builders.run_planners(Builders.snapshot(records: [ Builders.record(id: 1) ], hl: [ Builders.hl_contact(id: "A", phone: "+447000000000") ],
                                                   links: [ Builders.link(io_id: 1, hl: "A") ]))
    plan.problem("something odd")
    report = IoSync::Report.new(run_id: "r1", mode: :plan, started_at: Time.now, writes_enabled: false).load_plan(plan)
    report.status = :planned
    mail = described_class.report(report)
    expect(mail.to).to eq([ "ops@example.test" ])
    expect(mail.subject).to eq("IoSync plan planned: 2 changes, 1 problems")
    html = mail.html_part.body.to_s
    expect(html).to include("something odd", "+447000000000", "+447911123456", "update")
    expect(mail.attachments.first.filename).to eq("io_sync-r1.json")
    expect(JSON.parse(mail.attachments.first.body.to_s)["run_id"]).to eq("r1")
  end

  it "sends a plain-English summary with DND, lost links, number clashes, orphans and failures" do
    IoSync.configure do |c|
      Builders.config.instance_variables.each { |iv| c.instance_variable_set(iv, Builders.config.instance_variable_get(iv)) }
      c.summary_mail_to = "summary@example.test"
      c.hl_client_ref_field_id = "cfRef"
    end
    restricted = Builders.record(id: 1, details: { status: "Restricted Processing", first: "Jamie", last: "Rowe" })
    blocked = Builders.record(id: 2, details: { first: "Ann", last: "Other" }, contactdetails: Builders.contactdetails(email: "ann@example.test"))
    orphan = Builders.hl_contact(id: "ORPH", email: "quinn@example.test", first: "Quinn", last: "Ellis",
                                 custom_fields: [ { "id" => "cfRef", "value" => "1000001-90000001" } ])
    s = Builders.snapshot(records: [ restricted, blocked ],
                          hl: [ Builders.hl_contact(id: "A", first: "Jamie", last: "Rowe", dnd: nil), orphan ],
                          zoom: [ Builders.zoom_contact(external_id: "OTHER", io_id: 99, numbers: [ "+447911123456" ]) ],
                          links: [ Builders.link(io_id: 1, hl: "A"), Builders.link(io_id: 7, hl: "GONE") ],
                          listed: { client: [ 1, 2, 7 ], lead: [] })
    s.io_listed_ids = { client: Set[1, 2], lead: Set[] }
    plan = Builders.run_planners(s, config: IoSync.config)
    report = IoSync::Report.new(run_id: "r2", mode: :apply, started_at: Time.utc(2026, 10, 29, 12), writes_enabled: true).load_plan(plan)
    report.status = :applied
    report.writes.each { |a| a.result = { status: :ok } }
    report.writes.detect { |a| a.kind == :create }&.result = { status: :error, message: "HL said no" }

    mail = described_class.summary(report)
    expect(mail.to).to eq([ "summary@example.test" ])
    expect(mail.subject).to start_with("Intelliflo sync completed:").and include(", 1 DND,")
    report.actions.detect { |a| a.kind == :dnd }.result = { status: :unapproved }
    expect(described_class.summary(report).subject).to include(", 0 DND,")
    html = mail.html_part ? mail.html_part.body.to_s : mail.body.to_s
    expect(html).to include("Moved to do-not-disturb (1)", "Jamie Rowe", "Restricted processing")
    expect(html).to include("lost their Intelliflo link", "no longer listed by Intelliflo")
    expect(html).to include("could not go on Zoom (2)", "+447911123456", "Zoom contact OTHER")
    expect(described_class.report(report).html_part.body.to_s).to include("Zoom number conflicts (2)", "Quinn Ellis")
    expect(html).to include("no live Intelliflo record (1)", "Quinn Ellis (HL ORPH)", "Client Ref IO 90000001")
    expect(html).to include("Changes that failed", "HL said no")
    expect(mail.attachments).to be_empty
  end
end
