module IoSync
  module Clients
    # Read-only by construction: there are no write methods, and the connection
    # is never built writable. Intelliflo is the master.
    class Intelliflo
      attr_reader :calls

      def initialize(config:, connection: nil, token_connection: nil)
        @config = config
        @creds = config.credentials_for(:intelliflo)
        @limiter = Http::RateLimiter.new(requests_per_second: config.io_requests_per_second, name: "intelliflo")
        @connection = connection || Http.connection(config.intelliflo_base_url, service: "intelliflo", limiter: @limiter, logger: config.logger)
        @token_connection = token_connection || Http.connection(config.intelliflo_token_url, service: "intelliflo-token", logger: config.logger)
        @token = nil
        @token_mutex = Mutex.new
        @calls = Concurrent::AtomicFixnum.new(0)
      end

      def clients
        paginate("clients")
      end

      def leads
        paginate("leads")
      end

      def client(id)
        get("clients/#{id}")
      end

      def lead(id)
        get("leads/#{id}")
      end

      # type is :client or :lead
      def contactdetails(type, id)
        items(get("#{type}s/#{id}/contactdetails"))
      end

      def addresses(id)
        items(get("clients/#{id}/addresses"))
      end

      def plans(id)
        items(get("clients/#{id}/plans"))
      end

      def vulnerability(id)
        body = get("clients/#{id}/vulnerabilities/current")
        body.is_a?(Hash) && body.any? ? body : nil
      end

      def users(ids)
        return [] if ids.empty?
        paginate("users", params: { filter: "id in (#{ids.map(&:to_i).join(',')})" })
      end

      private

      def items(body)
        body.is_a?(Hash) ? Array(body["items"]) : []
      end

      def paginate(path, params: {})
        results = []
        body = get(path, params)
        loop do
          results.concat(items(body))
          next_href = body.is_a?(Hash) ? body["next_href"] : nil
          break if next_href.to_s.empty?
          body = get(next_href)
        end
        results
      end

      def get(path, params = {})
        attempt = 0
        begin
          @calls.increment
          response = @connection.get(path, params) do |req|
            req.headers["Authorization"] = "Bearer #{token}"
            req.headers["x-api-key"] = @creds[:api_key]
          end
          response.body
        rescue ApiError => e
          # One token refresh on 401; anything else propagates.
          raise unless e.status == 401 && attempt.zero?
          attempt += 1
          refresh_token!
          retry
        end
      end

      def token
        @token_mutex.synchronize { @token ||= fetch_token }
      end

      def refresh_token!
        @token_mutex.synchronize { @token = fetch_token }
      end

      def fetch_token
        basic = Base64.strict_encode64("#{@creds[:client_id]}:#{@creds[:client_secret]}")
        response = @token_connection.post("") do |req|
          req.headers["Authorization"] = "Basic #{basic}"
          req.headers["Content-Type"] = "application/x-www-form-urlencoded"
          req.body = URI.encode_www_form(grant_type: "tenant_client_credentials", tenant_id: @creds[:tenant_id])
        end
        token = response.body.is_a?(Hash) ? response.body["access_token"] : nil
        raise ApiError.new("Intelliflo token response had no access_token", service: "intelliflo-token") if token.to_s.empty?
        token
      end
    end
  end
end
