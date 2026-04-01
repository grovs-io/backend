class Removenotnullconstraintfromsubdomain < ActiveRecord::Migration[7.0]
  def change
    change_column_null :domains, :subdomain, true
  end
end
