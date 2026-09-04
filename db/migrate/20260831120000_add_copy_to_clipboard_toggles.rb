class AddCopyToClipboardToggles < ActiveRecord::Migration[8.1]
  def change
    add_column :links, :copy_to_clipboard_ios, :boolean
    add_column :links, :copy_to_clipboard_android, :boolean
    add_column :redirect_configs, :copy_to_clipboard_ios, :boolean, default: false, null: false
    add_column :redirect_configs, :copy_to_clipboard_android, :boolean, default: false, null: false
  end
end
