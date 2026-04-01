class RemoveNullConstraintsConfigurations < ActiveRecord::Migration[6.1]
  def change
    change_column_null :ios_configurations, :bundle_id, true
  end
end
