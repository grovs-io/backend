class RemoveCustomRedirectsFromLinks < ActiveRecord::Migration[7.0]
  def change
    remove_column :links, :ios_custom_redirect, :string
    remove_column :links, :android_custom_redirect, :string
    remove_column :links, :desktop_custom_redirect, :string
  end
end
