class AddDomainToWebConfigrationLink < ActiveRecord::Migration[6.1]
  def change
    add_column :web_configurations, :domain, :string
  end
end
