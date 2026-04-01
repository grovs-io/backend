class ChangeNameToPlatformGenerated < ActiveRecord::Migration[7.0]
  def change
    rename_column :links, :name, :generated_from_platform
  end
end
