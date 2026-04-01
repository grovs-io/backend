class AddUriSchemeToInstance < ActiveRecord::Migration[6.1]
  def change
    add_column :instances, :uri_scheme, :string, null: false
  end
end
