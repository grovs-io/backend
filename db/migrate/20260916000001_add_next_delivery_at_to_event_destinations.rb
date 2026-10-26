class AddNextDeliveryAtToEventDestinations < ActiveRecord::Migration[8.1]
  def change
    add_column :event_destinations, :next_delivery_at, :datetime
  end
end
