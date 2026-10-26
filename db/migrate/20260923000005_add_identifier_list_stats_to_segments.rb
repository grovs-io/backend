class AddIdentifierListStatsToSegments < ActiveRecord::Migration[8.1]
  def change
    add_column :segments, :identifier_list_count, :integer
    add_column :segments, :identifier_list_updated_at, :datetime
  end
end
