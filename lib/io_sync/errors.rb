module IoSync
  class Error < StandardError; end

  # Raised when anything tries to write to HighLevel or Zoom while writes are
  # not enabled, or through a connection that was not built writable.
  class WriteDisabled < Error; end

  # Raised when an API keeps answering 429 after the retry budget is spent.
  class RateLimited < Error; end

  # Raised when a run cannot produce a trustworthy plan (incomplete reads).
  class Aborted < Error; end

  class ApiError < Error
    attr_reader :status, :body, :service

    def initialize(message, status: nil, body: nil, service: nil)
      super(message)
      @status = status
      @body = body
      @service = service
    end
  end
end
