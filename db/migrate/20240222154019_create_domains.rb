class CreateDomains < ActiveRecord::Migration[6.1]
  def change
    create_table :domains do |t|
      t.string :domain, null: false, unique: true
      t.string :generic_title
      t.string :generic_subtitle

      t.timestamps
    end
  end
end
