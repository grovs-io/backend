class AddEngagementTimeToEvents < ActiveRecord::Migration[6.1]
  def change
    add_column :events, :engagement_time, :integer
  end
end
