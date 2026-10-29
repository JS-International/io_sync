module IoSync
  module Clients
    class Zoom
      attr_reader :calls

      def initialize(config:, writable: false, connection: nil, token_connection: nil)
        @config = config
        @creds = config.credentials_for(:zoom)
        @limiter = Http::RateLimiter.new(requests_per_second: config.zoom_requests_per_second, name: "zoom")
        @connection = connection || Http.connection(config.zoom_base_url, service: "zoom", writable: writable,
                                                    limiter: @limiter, logger: config.logger)
        @token_connection = token_connection || Http.connection(config.zoom_token_url, service: "zoom-token", logger: config.logger)
        @token = nil
        @calls = Concurrent::AtomicFixnum.new(0)
      end

      # All external contacts in the account. Each carries "id", the
      # customer-set id, which this integration sets to the Intelliflo id.
      def external_contacts(page_size: @config.zoom_page_size)
        contacts = []
        params = { "page_size" => page_size }
        loop do
          body = request(:get, "phone/external_contacts", params: params)
          contacts.concat(Array(body["external_contacts"]))
          token = body["next_page_token"].to_s
          break if token.empty?
          params = { "page_size" => page_size, "next_page_token" => token }
        end
        contacts
      end

      # The account's own phone numbers (users, auto receptionists, unassigned).
      # Zoom refuses an external contact holding any of them.
      def account_numbers(page_size: @config.zoom_page_size)
        numbers = []
        params = { "page_size" => page_size, "type" => "all" }
        loop do
          body = request(:get, "phone/numbers", params: params)
          numbers.concat(Array(body["phone_numbers"]))
          token = body["next_page_token"].to_s
          break if token.empty?
          params = params.merge("next_page_token" => token)
        end
        numbers
      end

      def create_contact(payload)
        request(:post, "phone/external_contacts", body: payload)
      end

      def update_contact(external_contact_id, payload)
        request(:patch, "phone/external_contacts/#{external_contact_id}", body: payload)
      end

      def delete_contact(external_contact_id)
        request(:delete, "phone/external_contacts/#{external_contact_id}")
      end

      private

      def request(method, path, params: nil, body: nil)
        @calls.increment
        response = @connection.run_request(method, path, body, { "Authorization" => "Bearer #{token}" }) do |req|
          req.params.update(params) if params
        end
        response.body.is_a?(Hash) ? response.body : {}
      end

      def token
        @token ||= begin
          basic = Base64.strict_encode64("#{@creds[:client_id]}:#{@creds[:client_secret]}")
          response = @token_connection.post("") do |req|
            req.headers["Authorization"] = "Basic #{basic}"
            req.headers["Content-Type"] = "application/x-www-form-urlencoded"
            req.body = URI.encode_www_form(grant_type: "account_credentials", account_id: @creds[:account_id])
          end
          t = response.body.is_a?(Hash) ? response.body["access_token"] : nil
          raise ApiError.new("Zoom token response had no access_token", service: "zoom-token") if t.to_s.empty?
          t
        end
      end
    end
  end
end
