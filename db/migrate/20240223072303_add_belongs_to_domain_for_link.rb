class AddBelongsToDomainForLink < ActiveRecord::Migration[6.1]
  def change
    add_reference :links, :domain, foreign_key: true
  end
end
