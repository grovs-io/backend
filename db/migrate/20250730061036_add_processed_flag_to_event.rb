class AddProcessedFlagToEvent < ActiveRecord::Migration[7.0]
  def change
    add_column :events, :processed, :boolean, default: false
  end
end
