module ApiStubs
  IO = "https://api.gb.intelliflo.net/v2".freeze
  HL = "https://services.leadconnectorhq.com".freeze
  ZOOM = "https://api.zoom.us/v2".freeze

  def json(body, status: 200)
    { status: status, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  end

  def stub_intelliflo(clients: [], leads: [], contactdetails: {}, addresses: {}, plans: {}, vulnerability: {}, users: [])
    stub_request(:post, "https://identity.intelliflo.com/core/connect/token").to_return(json({ access_token: "io-token" }))
    stub_request(:get, "#{IO}/clients").to_return(json({ items: clients }))
    stub_request(:get, "#{IO}/leads").to_return(json({ items: leads }))
    (clients + leads).each do |d|
      id = d["id"]
      kind = d["type"] == "Lead" ? "leads" : "clients"
      stub_request(:get, "#{IO}/#{kind}/#{id}/contactdetails").to_return(json({ items: contactdetails.fetch(id, []) }))
      next if kind == "leads"
      stub_request(:get, "#{IO}/clients/#{id}/addresses").to_return(json({ items: addresses.fetch(id, []) }))
      stub_request(:get, "#{IO}/clients/#{id}/plans").to_return(json({ items: plans.fetch(id, []) }))
      v = vulnerability[id]
      stub_request(:get, "#{IO}/clients/#{id}/vulnerabilities/current").to_return(v ? json(v) : { status: 204, body: "" })
    end
    stub_request(:get, %r{#{IO}/users}).to_return(json({ items: users }))
  end

  def stub_high_level(contacts: [], custom_fields: [])
    stub_request(:post, "#{HL}/contacts/search").to_return(json({ contacts: contacts, total: contacts.size }))
    stub_request(:get, %r{#{HL}/locations/\w+/customFields}).to_return(json({ customFields: custom_fields }))
  end

  def stub_zoom(contacts: [], account_numbers: [])
    stub_request(:post, "https://zoom.us/oauth/token").to_return(json({ access_token: "zoom-token" }))
    stub_request(:get, %r{#{ZOOM}/phone/external_contacts}).to_return(json({ external_contacts: contacts, next_page_token: "" }))
    stub_request(:get, %r{#{ZOOM}/phone/numbers}).to_return(json({ phone_numbers: account_numbers, next_page_token: "" }))
  end

  # Every non-GET request made so far that is not a read-via-POST or token call.
  def write_requests
    WebMock::RequestRegistry.instance.requested_signatures.hash.keys.select do |sig|
      sig.method != :get && !sig.uri.to_s.match?(%r{/contacts/search|/oauth/token|/core/connect/token})
    end
  end
end

RSpec.configure { |c| c.include ApiStubs }
