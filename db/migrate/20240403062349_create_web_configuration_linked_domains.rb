class CreateWebConfigurationLinkedDomains < ActiveRecord::Migration[6.1]
  def change
    create_table :web_configuration_linked_domains do |t|
      t.belongs_to :web_configuration

      t.timestamps
    end
  end
end
