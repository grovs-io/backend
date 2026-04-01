class UpdateRedirectPreviewColumns < ActiveRecord::Migration[7.0]
  def change
    rename_column :redirect_configs, :show_preview, :show_preview_ios
    add_column :redirect_configs, :show_preview_android, :boolean
  end
end
