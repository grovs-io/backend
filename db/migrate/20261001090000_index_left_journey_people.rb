class IndexLeftJourneyPeople < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # The nightly prune finds a journey's old leavers without reading the rows still inside.
  def change
    add_index :journey_people, %i[journey_id left_at], where: "state = 'left'", algorithm: :concurrently, name: "index_journey_people_left"
  end
end
