module IoSync
  module Http
    # Faraday middleware. Refuses every non-GET request unless the connection
    # was built with writable: true, except for the handful of POSTs that are
    # really reads (HighLevel contact search) or token exchanges.
    class WriteGuard < Faraday::Middleware
      READ_VIA_POST = [
        %r{/contacts/search\z},
        %r{/oauth/token\z},
        %r{/core/connect/token\z}
      ].freeze

      def initialize(app, writable: false)
        super(app)
        @writable = writable
      end

      def call(env)
        unless @writable || env.method == :get || env.method == :head || read_via_post?(env)
          raise WriteDisabled, "#{env.method.to_s.upcase} #{env.url} refused: connection is read-only"
        end
        @app.call(env)
      end

      private

      def read_via_post?(env)
        env.method == :post && READ_VIA_POST.any? { |re| env.url.path.match?(re) }
      end
    end
  end
end
