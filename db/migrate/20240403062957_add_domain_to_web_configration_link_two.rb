class AddDomainToWebConfigrationLinkTwo < ActiveRecord::Migration[6.1]
  def change
    add_column :web_configuration_linked_domains, :domain, :string
    remove_column :web_configurations, :domain
  end
end
