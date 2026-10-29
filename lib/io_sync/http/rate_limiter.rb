module IoSync
  module Http
    # Token bucket shared across threads, plus awareness of HighLevel's
    # X-RateLimit-* response headers: when the remaining burst budget is nearly
    # gone we sleep for the rest of the interval.
    class RateLimiter
      def initialize(requests_per_second:, name: "api", clock: Process.method(:clock_gettime))
        @rate = requests_per_second.to_f
        @name = name
        @clock = clock
        @mutex = Mutex.new
        @tokens = @rate
        @last = now
        @pause_until = nil
      end

      def wait
        loop do
          sleep_for = @mutex.synchronize do
            refill
            if @pause_until && now < @pause_until
              @pause_until - now
            elsif @tokens >= 1
              @tokens -= 1
              0
            else
              (1 - @tokens) / @rate
            end
          end
          return if sleep_for <= 0
          sleep(sleep_for)
        end
      end

      def observe(headers)
        remaining = headers["x-ratelimit-remaining"]
        interval_ms = headers["x-ratelimit-interval-milliseconds"]
        return if remaining.nil? || interval_ms.nil?
        if remaining.to_i <= 3
          @mutex.synchronize { @pause_until = now + (interval_ms.to_f / 1000.0) }
        end
      end

      class Middleware < Faraday::Middleware
        def initialize(app, limiter:)
          super(app)
          @limiter = limiter
        end

        def call(env)
          @limiter.wait
          @app.call(env).on_complete do |response_env|
            @limiter.observe(response_env.response_headers || {})
          end
        end
      end

      private

      def now
        @clock.call(Process::CLOCK_MONOTONIC)
      end

      def refill
        t = now
        @tokens = [ @rate, @tokens + (t - @last) * @rate ].min
        @last = t
      end
    end
  end
end
