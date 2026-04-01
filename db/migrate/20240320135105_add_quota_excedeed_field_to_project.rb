class AddQuotaExcedeedFieldToProject < ActiveRecord::Migration[6.1]
  def change
    add_column :projects, :quota_exceeded_date, :timestamp
  end
end
