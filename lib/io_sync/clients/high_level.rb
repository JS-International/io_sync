module IoSync
  module Clients
    class HighLevel
      VERSION = "2021-07-28".freeze
      attr_reader :calls

      def initialize(config:, writable: false, connection: nil)
        @config = config
        @location_id = config.hl_location_id
        token = config.credentials_for(:high_level)[:private_integration_token]
        @limiter = Http::RateLimiter.new(requests_per_second: config.hl_requests_per_10s / 10.0, name: "high_level")
        headers = { "Authorization" => "Bearer #{token}", "Version" => VERSION, "Accept" => "application/json" }
        @connection = connection || Http.connection(config.high_level_base_url, service: "high_level", writable: writable,
                                                    limiter: @limiter, headers: headers, logger: config.logger)
        @calls = Concurrent::AtomicFixnum.new(0)
      end

      # Every contact in the location. The search body names the street field
      # "address"; GET /contacts/{id} names it "address1". We normalise to address1.
      def search_contacts(page_limit: @config.hl_page_limit)
        contacts = []
        page = 1
        loop do
          body = post("contacts/search", { "locationId" => @location_id, "page" => page, "pageLimit" => page_limit })
          batch = Array(body["contacts"])
          contacts.concat(batch.map { |c| normalise_contact(c) })
          total = body["total"].to_i
          break if batch.empty? || contacts.size >= total
          page += 1
        end
        contacts
      end

      def custom_fields
        Array(get("locations/#{@location_id}/customFields")["customFields"])
      end

      def get_contact(id)
        normalise_contact(get("contacts/#{id}")["contact"])
      end

      def create_contact(payload)
        body = post("contacts/", payload.merge("locationId" => @location_id))
        contact = body["contact"]
        raise ApiError.new("HighLevel create returned no contact: #{body['message']}", body: body, service: "high_level") unless contact
        normalise_contact(contact)
      end

      def update_contact(id, payload)
        body = put("contacts/#{id}", payload)
        contact = body["contact"]
        raise ApiError.new("HighLevel update returned no contact: #{body['message']}", body: body, service: "high_level") unless contact
        normalise_contact(contact)
      end

      def add_tags(id, tags)
        post("contacts/#{id}/tags", { "tags" => tags })
      end

      def remove_tags(id, tags)
        delete("contacts/#{id}/tags", { "tags" => tags })
      end

      def set_dnd(id, dnd_settings)
        put("contacts/#{id}", { "dndSettings" => dnd_settings })
      end

      private

      def normalise_contact(contact)
        return nil if contact.nil?
        c = contact.dup
        c["address1"] = c.delete("address") if c.key?("address") && !c.key?("address1")
        c
      end

      def get(path)
        @calls.increment
        @connection.get(path).body
      end

      def post(path, body)
        @calls.increment
        @connection.post(path, body).body
      end

      def put(path, body)
        @calls.increment
        @connection.put(path, body).body
      end

      def delete(path, body)
        @calls.increment
        @connection.delete(path) { |req| req.body = body }.body
      end
    end
  end
end
