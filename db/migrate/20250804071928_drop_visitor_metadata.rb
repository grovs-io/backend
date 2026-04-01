class DropVisitorMetadata < ActiveRecord::Migration[7.0]
  def change
     drop_table :visitor_metadata
  end
end
