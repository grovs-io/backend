class AddCustomUrLsToLinks < ActiveRecord::Migration[7.0]
  def change
    add_column :links, :ios_custom_redirect, :string, default: nil
    add_column :links, :android_custom_redirect, :string, default: nil
    add_column :links, :desktop_custom_redirect, :string, default: nil
  end
end
