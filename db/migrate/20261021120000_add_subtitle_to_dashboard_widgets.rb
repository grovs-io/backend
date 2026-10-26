class AddSubtitleToDashboardWidgets < ActiveRecord::Migration[8.1]
  def change
    add_column :dashboard_widgets, :subtitle, :string
  end
end
