class AddVisitorReferenceToDevice < ActiveRecord::Migration[6.1]
  def change
    add_reference :devices, :visitor, foreign_key: true
  end
end
