class AddIndexForVendorOnEvents < ActiveRecord::Migration[6.1]
  def change
    add_index :events, :vendor_id
  end
end
