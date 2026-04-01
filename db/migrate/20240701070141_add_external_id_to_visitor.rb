class AddExternalIdToVisitor < ActiveRecord::Migration[6.1]
  def change
    add_column :visitors, :uuid, :uuid, default: 'gen_random_uuid()'
    add_index :visitors, :uuid, unique: true
  end
end
