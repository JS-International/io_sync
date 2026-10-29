require "spec_helper"
require "io_sync"

RSpec.describe IoSync::Phone do
  it "normalises UK formats to +44" do
    expect(described_class.normalise("07911 123 456")).to eq("+447911123456")
    expect(described_class.normalise("0044 7911 123456")).to eq("+447911123456")
    expect(described_class.normalise("(44) 7911 123456")).to eq("+447911123456")
    expect(described_class.normalise("[44]7911123456")).to eq("+447911123456")
    expect(described_class.normalise("+44 7911 123456")).to eq("+447911123456")
  end

  it "rejects blanks, annotations and invalid numbers" do
    expect(described_class.normalise(nil)).to be_nil
    expect(described_class.normalise("  ")).to be_nil
    expect(described_class.normalise("07911 123 459 (NOT VALID)")).to be_nil
    expect(described_class.normalise("07911-123-456")).to be_nil
    expect(described_class.normalise("12345")).to be_nil
  end
end
