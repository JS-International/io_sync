module IoSync
  # Storage for link rows. The engine provides an ActiveRecord-backed store;
  # this in-memory one is used by specs and by plan-only runs outside Rails.
  class MemoryLinkStore
    def initialize(rows = [])
      @rows = rows.to_h { |r| [ r.io_id, LinkRow.new(**r.to_h) ] }
    end

    def all = @rows.values.map(&:dup)
    def find(io_id) = @rows[io_id]&.dup

    # Keys given are set, even to nil; keys omitted are kept.
    def set(io_id, io_type: nil, **fields)
      row = @rows[io_id] || LinkRow.new(io_id: io_id, io_type: io_type.to_s)
      row.io_type = io_type.to_s if io_type
      fields.each { |k, v| row[k] = v }
      if row.hl_contact_id.nil? && row.zoom_external_contact_id.nil?
        @rows.delete(io_id)
      else
        @rows[io_id] = row
      end
      row.dup
    end

    def delete(io_id) = @rows.delete(io_id)
  end
end
