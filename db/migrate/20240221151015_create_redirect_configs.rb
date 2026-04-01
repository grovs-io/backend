class CreateRedirectConfigs < ActiveRecord::Migration[6.1]
  def change
    create_table :redirect_configs do |t|
      t.timestamps
    end
  end
end
