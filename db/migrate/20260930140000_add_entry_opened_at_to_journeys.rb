class AddEntryOpenedAtToJourneys < ActiveRecord::Migration[8.1]
  def change
    add_column :journeys, :entry_opened_at, :datetime
  end
end
