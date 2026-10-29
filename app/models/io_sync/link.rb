module IoSync
  # The only local state: which HighLevel contact and which Zoom external
  # contact belong to an Intelliflo record.
  class Link < ApplicationRecord
    self.table_name = "io_sync_links"

    IO_TYPES = %w[client lead].freeze

    validates :io_id, presence: true, uniqueness: true
    validates :io_type, inclusion: { in: IO_TYPES }
    validates :hl_contact_id, uniqueness: true, allow_nil: true
    validates :zoom_external_contact_id, uniqueness: true, allow_nil: true

    def to_row
      LinkRow.new(io_id: io_id, io_type: io_type, hl_contact_id: hl_contact_id, zoom_external_contact_id: zoom_external_contact_id)
    end

    def self.store = Store.new

    # Adapter with the same interface as IoSync::MemoryLinkStore.
    class Store
      def all = Link.order(:io_id).map(&:to_row)
      def find(io_id) = Link.find_by(io_id: io_id)&.to_row

      def set(io_id, io_type: nil, **fields)
        link = Link.find_or_initialize_by(io_id: io_id)
        link.io_type = io_type.to_s if io_type
        fields.each { |k, v| link[k] = v }
        if link.hl_contact_id.nil? && link.zoom_external_contact_id.nil?
          link.destroy if link.persisted?
        else
          link.save!
        end
        link.to_row
      end

      def delete(io_id) = Link.where(io_id: io_id).destroy_all
    end
  end
end
