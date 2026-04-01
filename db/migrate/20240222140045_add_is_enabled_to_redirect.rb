class AddIsEnabledToRedirect < ActiveRecord::Migration[6.1]
  def change
    add_column :redirects, :enabled, :boolean, default: true
  end
end
