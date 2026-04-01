class CreateDownloadableFiles < ActiveRecord::Migration[7.0]
  def change
    create_table :downloadable_files do |t|
      t.string :name
      t.timestamps
    end
  end
end
