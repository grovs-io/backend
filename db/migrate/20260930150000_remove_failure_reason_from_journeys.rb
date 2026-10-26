class RemoveFailureReasonFromJourneys < ActiveRecord::Migration[8.1]
  def change
    remove_column :journeys, :failure_reason, :string
  end
end
