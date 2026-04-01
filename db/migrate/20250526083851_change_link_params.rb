class ChangeLinkParams < ActiveRecord::Migration[7.0]
  def change
    rename_column :links, :show_preview, :show_preview_ios
    add_column :links, :show_preview_android, :boolean
  end
end
