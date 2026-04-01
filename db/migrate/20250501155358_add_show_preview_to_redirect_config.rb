class AddShowPreviewToRedirectConfig < ActiveRecord::Migration[7.0]
  def change
    add_column :redirect_configs, :show_preview, :boolean
  end
end
