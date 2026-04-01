class AddGetStartedDismissedInstance < ActiveRecord::Migration[7.0]
  def change
    add_column :instances, :get_started_dismissed, :boolean, default: false
  end
end
