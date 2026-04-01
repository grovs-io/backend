class AddVisitorIdToLink < ActiveRecord::Migration[6.1]
  def change
    add_reference :links, :visitor, foreign_key: true, null: true
  end
end
