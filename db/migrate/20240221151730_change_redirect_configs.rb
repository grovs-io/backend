class ChangeRedirectConfigs < ActiveRecord::Migration[6.1]
  def change
    add_reference :redirect_configs, :project, foreign_key: true
    add_column :redirect_configs, :default_fallback, :string, null: false
  end
end
