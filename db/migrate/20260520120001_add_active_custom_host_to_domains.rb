class AddActiveCustomHostToDomains < ActiveRecord::Migration[8.1]
  def change
    add_column :domains, :active_custom_host, :string
  end
end
