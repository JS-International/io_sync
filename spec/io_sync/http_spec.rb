require "spec_helper"
require "io_sync"

RSpec.describe "IoSync HTTP layer" do
  it "refuses writes on a read-only connection but allows the read-via-POST endpoints" do
    conn = IoSync::Http.connection("https://services.leadconnectorhq.com/", service: "hl")
    stub_request(:post, "https://services.leadconnectorhq.com/contacts/search").to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    expect { conn.post("contacts/search", {}) }.not_to raise_error
    expect { conn.post("contacts/", {}) }.to raise_error(IoSync::WriteDisabled)
    expect { conn.put("contacts/1", {}) }.to raise_error(IoSync::WriteDisabled)
    expect { conn.delete("contacts/1/tags") }.to raise_error(IoSync::WriteDisabled)
    expect(a_request(:post, "https://services.leadconnectorhq.com/contacts/")).not_to have_been_made
  end

  it "allows writes on a writable connection" do
    conn = IoSync::Http.connection("https://api.zoom.us/v2/", service: "zoom", writable: true)
    stub_request(:patch, "https://api.zoom.us/v2/phone/external_contacts/1").to_return(status: 204, body: "")
    expect(conn.patch("phone/external_contacts/1", {}).status).to eq(204)
  end

  it "retries 429 then raises RateLimited, and raises ApiError for other failures" do
    conn = IoSync::Http.connection("https://api.gb.intelliflo.net/v2/", service: "intelliflo")
    stub_request(:get, "https://api.gb.intelliflo.net/v2/clients").to_return(status: 429, body: "")
    expect { conn.get("clients") }.to raise_error(IoSync::RateLimited)
    expect(a_request(:get, "https://api.gb.intelliflo.net/v2/clients")).to have_been_made.times(2)
    stub_request(:get, "https://api.gb.intelliflo.net/v2/leads").to_return(status: 400, body: { message: "bad filter" }.to_json,
                                                                            headers: { "Content-Type" => "application/json" })
    expect { conn.get("leads") }.to raise_error(IoSync::ApiError, /400: bad filter/)
  end

  it "never logs headers or bodies" do
    io = StringIO.new
    conn = IoSync::Http.connection("https://api.gb.intelliflo.net/v2/", service: "intelliflo", logger: Logger.new(io))
    stub_request(:get, "https://api.gb.intelliflo.net/v2/clients").to_return(status: 200, body: '{"items":[]}', headers: { "Content-Type" => "application/json" })
    conn.get("clients") { |req| req.headers["Authorization"] = "Bearer SECRET-TOKEN" }
    expect(io.string).to include("clients")
    expect(io.string).not_to include("SECRET-TOKEN")
  end

  it "pauses when HighLevel reports the burst budget is nearly gone" do
    clock = [ 0.0 ]
    limiter = IoSync::Http::RateLimiter.new(requests_per_second: 1000, clock: ->(_) { clock[0] })
    limiter.observe("x-ratelimit-remaining" => "2", "x-ratelimit-interval-milliseconds" => "10000")
    allow(limiter).to receive(:sleep) { |s| clock[0] += s }
    limiter.wait
    expect(limiter).to have_received(:sleep).with(a_value >= 9.9)
  end
end
