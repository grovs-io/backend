class MakeDomainBelongToProject < ActiveRecord::Migration[6.1]
  def change
    add_reference :domains, :project, foreign_key: true
  end
end
