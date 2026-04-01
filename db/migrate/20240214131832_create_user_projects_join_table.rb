class CreateUserProjectsJoinTable < ActiveRecord::Migration[6.1]
  def change
    create_join_table :users, :projects do |t|
      t.index :project_id
      t.index :user_id
    end
  end
end
