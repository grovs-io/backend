class AddFieldsToRedirects < ActiveRecord::Migration[6.1]
  def change
    add_column :redirects, :appstore, :boolean, null: false
    add_column :redirects, :fallback_url, :string
    add_column :redirects, :variation, :string, null: false
    add_column :redirects, :platform, :string, null: false
    add_column :redirects, :redirect_to_generated_page, :boolean, null: false
  end
end
