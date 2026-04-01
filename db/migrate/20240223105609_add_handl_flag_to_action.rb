class AddHandlFlagToAction < ActiveRecord::Migration[6.1]
  def change
    add_column :actions, :handled, :boolean, default: false
  end
end
