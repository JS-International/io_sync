module IoSync
  # Executes a plan in a fixed order. Only ever built by Reconcile in apply
  # mode, with clients constructed writable. Each action's result is recorded
  # on the action; one failure does not stop the others.
  class Applier
    ORDER = [
      [ :link, :unlink ], [ :link, :relink ], [ :link, :link ], [ :link, :adopt ],
      [ :zoom, :delete ],
      [ :hl, :create ], [ :hl, :update ], [ :hl, :add_tags ], [ :hl, :remove_tags ], [ :hl, :dnd ],
      [ :zoom, :create ], [ :zoom, :update ]
    ].freeze

    def initialize(plan, config:, high_level:, zoom:, link_store:, approved_digests: nil)
      @plan = plan
      @config = config
      @high_level = high_level
      @zoom = zoom
      @link_store = link_store
      @approved = approved_digests && approved_digests.to_set
    end

    def call
      stopped = nil
      ordered_actions.each do |action|
        if stopped
          action.result = { status: :not_attempted, message: stopped }
          next
        end
        if @approved && !@approved.include?(action.digest)
          action.result = { status: :unapproved, message: "not in the approved plan (new or changed since review)" }
          next
        end
        begin
          action.result = apply(action)
        rescue RateLimited => e
          action.result = { status: :error, message: e.message }
          stopped = "stopped after rate limiting: #{e.message}"
        rescue StandardError => e
          action.result = { status: :error, message: "#{e.class}: #{e.message}" }
        end
      end
      @plan
    end

    private

    def ordered_actions
      ORDER.flat_map { |target, kind| @plan.actions.select { |a| a.target == target && a.kind == kind } }
    end

    def apply(action)
      case [ action.target, action.kind ]
      when [ :link, :unlink ]
        if action.payload && (action.payload["hl_contact_id"] || action.payload["zoom_external_contact_id"])
          @link_store.set(action.io_id, io_type: action.io_type, hl_contact_id: action.payload["hl_contact_id"],
                          zoom_external_contact_id: action.payload["zoom_external_contact_id"])
        else
          @link_store.delete(action.io_id)
        end
        ok
      when [ :link, :relink ]
        @link_store.set(action.payload["from_io_id"], hl_contact_id: nil)
        @link_store.set(action.payload["to_io_id"], io_type: action.io_type, hl_contact_id: action.payload["hl_contact_id"])
        ok(action.payload["hl_contact_id"])
      when [ :link, :link ]
        @link_store.set(action.io_id, io_type: action.io_type, hl_contact_id: action.payload["hl_contact_id"])
        ok(action.payload["hl_contact_id"])
      when [ :link, :adopt ]
        @link_store.set(action.io_id, io_type: action.io_type, zoom_external_contact_id: action.payload["zoom_external_contact_id"])
        ok(action.payload["zoom_external_contact_id"])
      when [ :zoom, :delete ]
        @zoom.delete_contact(action.remote_id)
        @link_store.set(action.io_id, io_type: action.io_type, zoom_external_contact_id: nil) if @link_store.find(action.io_id)
        ok(action.remote_id)
      when [ :hl, :create ]
        contact = @high_level.create_contact(action.payload)
        @link_store.set(action.io_id, io_type: action.io_type, hl_contact_id: contact["id"])
        ok(contact["id"])
      when [ :hl, :update ]
        @high_level.update_contact(action.remote_id, action.payload)
        ok(action.remote_id)
      when [ :hl, :add_tags ]
        id = hl_id_for(action)
        @high_level.add_tags(id, action.payload["tags"])
        ok(id)
      when [ :hl, :remove_tags ]
        id = hl_id_for(action)
        @high_level.remove_tags(id, action.payload["tags"])
        ok(id)
      when [ :hl, :dnd ]
        @high_level.set_dnd(action.remote_id, action.payload["dndSettings"])
        ok(action.remote_id)
      when [ :zoom, :create ]
        body = @zoom.create_contact(action.payload)
        ext = body["external_contact_id"]
        raise ApiError.new("Zoom create returned no external_contact_id", body: body, service: "zoom") if ext.to_s.empty?
        @link_store.set(action.io_id, io_type: action.io_type, zoom_external_contact_id: ext)
        ok(ext)
      when [ :zoom, :update ]
        @zoom.update_contact(action.remote_id, action.payload)
        ok(action.remote_id)
      else
        { status: :error, message: "unknown action #{action.target}/#{action.kind}" }
      end
    end

    # Tag actions planned alongside a create have no remote id yet.
    def hl_id_for(action)
      action.remote_id || @link_store.find(action.io_id)&.hl_contact_id or
        raise Error, "no HL contact id for IO #{action.io_id} (create failed?)"
    end

    def ok(remote_id = nil)
      { status: :ok, remote_id: remote_id }
    end
  end
end
