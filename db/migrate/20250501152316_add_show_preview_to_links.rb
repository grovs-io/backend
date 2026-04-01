class AddShowPreviewToLinks < ActiveRecord::Migration[7.0]
  def change
    add_column :links, :show_preview, :boolean
  end
end
