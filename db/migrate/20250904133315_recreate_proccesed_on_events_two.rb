class RecreateProccesedOnEventsTwo < ActiveRecord::Migration[7.0]
  def change
     remove_column :events, :processed
    add_column :events, :processed, :boolean, default: false, null: false
  end
end
