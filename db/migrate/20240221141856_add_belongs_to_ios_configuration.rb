class AddBelongsToIosConfiguration < ActiveRecord::Migration[6.1]
  def change
    add_reference :ios_configurations, :application, foreign_key: true
  end
end
