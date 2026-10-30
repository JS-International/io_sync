require "rails_helper"

RSpec.describe IoSync::ReconcileJob, type: :job do
  it "defaults to plan mode and returns the summary" do
    report = IoSync::Report.new(run_id: "r", mode: :plan, started_at: Time.now, writes_enabled: false)
    report.status = :planned
    expect(IoSync).to receive(:reconcile).with(mode: :plan, approved: nil).and_return(report)
    expect(described_class.perform_now).to include("plan run r planned")
  end

  it "plans instead of applying while the write kill switch is off" do
    report = IoSync::Report.new(run_id: "r", mode: :plan, started_at: Time.now, writes_enabled: false)
    report.status = :planned
    allow(IoSync.config).to receive(:writes_enabled).and_return(false)
    expect(IoSync).to receive(:reconcile).with(mode: :plan, approved: nil).and_return(report)
    expect(described_class.perform_now("apply")).to include("plan run r planned")
  end

  it "applies when the write kill switch is on" do
    report = IoSync::Report.new(run_id: "r", mode: :apply, started_at: Time.now, writes_enabled: true)
    report.status = :applied
    allow(IoSync.config).to receive(:writes_enabled).and_return(true)
    expect(IoSync).to receive(:reconcile).with(mode: :apply, approved: nil).and_return(report)
    expect(described_class.perform_now("apply")).to include("apply run r applied")
  end

  it "raises when the run aborted so the queue records the failure" do
    report = IoSync::Report.new(run_id: "r", mode: :plan, started_at: Time.now, writes_enabled: false)
    report.status = :aborted
    report.error = "incomplete"
    allow(IoSync).to receive(:reconcile).and_return(report)
    expect { described_class.perform_now }.to raise_error(IoSync::Aborted, "incomplete")
  end
end
