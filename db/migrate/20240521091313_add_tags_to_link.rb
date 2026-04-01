class AddTagsToLink < ActiveRecord::Migration[6.1]
  def change
    add_column :links, :tags, :text, array: true, default: []
  end
end
