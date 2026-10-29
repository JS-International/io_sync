module IoSync
  # One intended change (or a deliberate non-change). payload is exactly what
  # would be sent; diff is old => new per field; digest identifies the action
  # across runs so a reviewed plan can be applied later.
  Action = Struct.new(:target, :kind, :io_id, :io_type, :io_name, :email, :remote_id, :reason,
                      :payload, :diff, :digest, :result, keyword_init: true) do
    def noop? = kind == :noop
    def write? = !%i[noop skip conflict prune_skipped].include?(kind)

    def compute_digest!
      self.digest = Digest::SHA256.hexdigest(Plan.canonical_json([ target.to_s, kind.to_s, io_id, remote_id, digest_payload ]))
      self
    end

    # The DND message carries the run time, so it is left out of the digest;
    # otherwise a reviewed DND action could never match at apply time.
    def digest_payload
      return payload unless kind.to_s == "dnd" && payload.is_a?(Hash) && payload["dndSettings"].is_a?(Hash)
      { "dndSettings" => payload["dndSettings"].transform_values { |v| v.is_a?(Hash) ? v.except("message") : v } }
    end

    def to_h
      {
        target: target, kind: kind, io_id: io_id, io_type: io_type, io_name: io_name, email: email,
        remote_id: remote_id, reason: reason, payload: payload, diff: diff, digest: digest, result: result
      }
    end

    def self.from_h(h)
      h = h.transform_keys(&:to_sym)
      new(**h.slice(*members)).tap do |a|
        a.target = a.target&.to_sym
        a.kind = a.kind&.to_sym
        if a.result.is_a?(Hash)
          a.result = a.result.transform_keys(&:to_sym)
          a.result[:status] = a.result[:status]&.to_sym
        end
      end
    end
  end

  class Plan
    attr_reader :actions, :problems, :stats, :notes

    def initialize
      @actions = []
      @problems = []
      @stats = {}
      @notes = {}
    end

    def add(**attrs)
      action = Action.new(**attrs).compute_digest!
      @actions << action
      action
    end

    def problem(message)
      @problems << message
    end

    # Oddities for people to look at that are not actions: category => [{ io_id:, name:, detail: }].
    def note(category, io_id: nil, name: nil, detail:)
      (@notes[category] ||= []) << { io_id: io_id, name: name, detail: detail }
    end

    def counts
      actions.group_by(&:target).transform_values { |as| as.group_by(&:kind).transform_values(&:size) }
    end

    def writes = actions.select(&:write?)
    def for(target) = actions.select { |a| a.target == target }

    def self.canonical_json(value)
      JSON.generate(canonicalise(value))
    end

    def self.canonicalise(value)
      case value
      when Hash then value.map { |k, v| [ k.to_s, canonicalise(v) ] }.sort_by(&:first).to_h
      when Array then value.map { |v| canonicalise(v) }
      else value
      end
    end
  end
end
