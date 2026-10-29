module IoSync
  module Http
    RETRY_OPTIONS = {
      max: 5,
      interval: 1,
      interval_randomness: 0.2,
      backoff_factor: 2,
      retry_statuses: [ 429, 500, 502, 503, 504 ],
      methods: %i[get head post put patch delete]
    }.freeze

    # Overridable so specs can shrink the backoff.
    def self.retry_options = RETRY_OPTIONS

    # Builds a Faraday connection with TLS verification on, JSON in and out,
    # exponential retries that honour Retry-After, the write guard, an optional
    # rate limiter and a logger that records only method, path, status and timing.
    def self.connection(base_url, service:, writable: false, limiter: nil, headers: {}, logger: nil)
      Faraday.new(url: base_url, headers: headers, ssl: { verify: true }) do |f|
        f.request :json
        f.use RaiseErrors, service: service
        f.request :retry, retry_options
        f.use WriteGuard, writable: writable
        f.use RateLimiter::Middleware, limiter: limiter if limiter
        f.response :json, content_type: /\bjson/, parser_options: { symbolize_names: false }
        f.response :logger, logger, headers: false, bodies: false, errors: true if logger
        f.adapter Faraday.default_adapter
      end
    end
  end
end
