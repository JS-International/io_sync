require "rails_helper"

RSpec.describe IoSync::Link, type: :model do
  let(:store) { described_class.store }

  it "sets, merges and removes rows" do
    store.set(1, io_type: "client", hl_contact_id: "A")
    store.set(1, zoom_external_contact_id: "Z")
    expect(store.find(1).to_h).to include(io_type: "client", hl_contact_id: "A", zoom_external_contact_id: "Z")
    store.set(1, hl_contact_id: nil)
    expect(store.find(1).hl_contact_id).to be_nil
    store.set(1, zoom_external_contact_id: nil)
    expect(store.find(1)).to be_nil
  end

  it "enforces one link per remote record" do
    store.set(1, io_type: "client", hl_contact_id: "A")
    expect { store.set(2, io_type: "client", hl_contact_id: "A") }.to raise_error(ActiveRecord::RecordInvalid)
    expect { store.set(3, io_type: "trust", hl_contact_id: "B") }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
