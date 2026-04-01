class AddWebFlagToVisitor < ActiveRecord::Migration[6.1]
  def change
    add_column :visitors, :web_visitor, :boolean, default: false
  end
end
