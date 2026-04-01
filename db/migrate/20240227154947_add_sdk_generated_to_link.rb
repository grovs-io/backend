class AddSdkGeneratedToLink < ActiveRecord::Migration[6.1]
  def change
    add_column :links, :sdk_generated, :boolean, default: false
  end
end
