class CreateIoSyncLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :io_sync_links do |t|
      t.integer :io_id, null: false
      t.string :io_type, null: false
      t.string :hl_contact_id
      t.string :zoom_external_contact_id
      t.timestamps
    end
    add_index :io_sync_links, :io_id, unique: true
    add_index :io_sync_links, :hl_contact_id, unique: true, where: "hl_contact_id IS NOT NULL"
    add_index :io_sync_links, :zoom_external_contact_id, unique: true, where: "zoom_external_contact_id IS NOT NULL"
    add_check_constraint :io_sync_links, "io_type IN ('client','lead')", name: "io_sync_links_io_type"
  end
end
