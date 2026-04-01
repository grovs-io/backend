class RedoProjectsInstanceLink < ActiveRecord::Migration[6.1]
  def change
    add_reference :projects, :instance, foreign_key: true
    remove_column :instances, :test_id
    remove_column :instances, :production_id
  end
end
