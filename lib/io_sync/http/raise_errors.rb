module IoSync
  module Http
    # Sits outside the retry middleware, so it only sees the final response.
    class RaiseErrors < Faraday::Middleware
      def initialize(app, service:)
        super(app)
        @service = service
      end

      def call(env)
        @app.call(env).on_complete do |response_env|
          status = response_env.status
          next if status.between?(200, 299) || status == 304
          body = response_env.body
          message = "#{@service} #{response_env.method.to_s.upcase} #{response_env.url.path} returned #{status}"
          detail = body.is_a?(Hash) ? (body["message"] || body["error"] || body["error_description"]) : body.to_s[0, 200]
          message += ": #{Array(detail).join('; ')}" if detail && !detail.to_s.empty?
          raise RateLimited, message if status == 429
          raise ApiError.new(message, status: status, body: body, service: @service)
        end
      end
    end
  end
end
