require "spec_helper"
require "io_sync"
require_relative "../support/builders"

RSpec.describe IoSync::Report do
  it "round-trips through JSON with digests intact" do
    plan = run_planners(snapshot(records: [ record(id: 1) ]))
    report = described_class.new(run_id: "r1", mode: :plan, started_at: Time.utc(2026, 10, 28), writes_enabled: false).load_plan(plan)
    report.status = :planned
    back = described_class.from_json(report.to_json)
    expect(back.run_id).to eq("r1")
    expect(back.digests).to eq(report.digests)
    expect(back.actions.first.payload).to eq(plan.actions.first.payload)
    expect(back.summary_line).to include("plan run r1 planned", "1 create")

    report.actions.first.result = { status: :ok, remote_id: "NEW" }
    expect(described_class.from_json(report.to_json).actions.first.result).to eq(status: :ok, remote_id: "NEW")
  end
end
