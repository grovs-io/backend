class CreateRedirects < ActiveRecord::Migration[6.1]
  def change
    create_table :redirects do |t|

      t.timestamps
    end
  end
end
