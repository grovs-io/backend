class MakeDefaultFallbackOptional < ActiveRecord::Migration[6.1]
  def change
    change_column :redirect_configs, :default_fallback, :string, null: true
  end
end
