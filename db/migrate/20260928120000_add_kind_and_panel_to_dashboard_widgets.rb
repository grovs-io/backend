class AddKindAndPanelToDashboardWidgets < ActiveRecord::Migration[8.1]
  def change
    add_column :dashboard_widgets, :kind, :string, null: false, default: 'metric'
    add_column :dashboard_widgets, :panel, :string
  end
end
