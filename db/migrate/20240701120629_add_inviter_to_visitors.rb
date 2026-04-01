class AddInviterToVisitors < ActiveRecord::Migration[6.1]
  def change
    add_column :visitors, :inviter_id, :integer
  end
end
