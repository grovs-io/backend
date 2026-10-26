class AddJourneysToPushAndInApp < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :push_deliveries, :journey_person_id, :bigint
    add_column :in_app_settings, :push_daily_cap, :integer
    add_index :push_deliveries, %i[push_campaign_id visitor_id], unique: true, algorithm: :concurrently,
                                                                 where: "visitor_id IS NOT NULL AND journey_person_id IS NULL",
                                                                 name: "index_push_deliveries_on_campaign_and_visitor_new"
    remove_index :push_deliveries, name: "index_push_deliveries_on_campaign_and_visitor", algorithm: :concurrently
    rename_index :push_deliveries, "index_push_deliveries_on_campaign_and_visitor_new", "index_push_deliveries_on_campaign_and_visitor"
    add_index :push_deliveries, :created_at, where: "journey_person_id IS NOT NULL", algorithm: :concurrently,
                                             name: "index_push_deliveries_journey_age"
  end

  def down
    remove_index :push_deliveries, name: "index_push_deliveries_journey_age"
    remove_index :push_deliveries, name: "index_push_deliveries_on_campaign_and_visitor"
    add_index :push_deliveries, %i[push_campaign_id visitor_id], unique: true, where: "visitor_id IS NOT NULL",
                                                                 name: "index_push_deliveries_on_campaign_and_visitor"
    remove_column :in_app_settings, :push_daily_cap
    remove_column :push_deliveries, :journey_person_id
  end
end
