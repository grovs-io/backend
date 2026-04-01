class AddIndexesToLinksAndInstances < ActiveRecord::Migration[7.0]
  def change
    unless index_exists?(:links, :path)
      add_index :links, :path
    end

    unless index_exists?(:instances, :uri_scheme)
      add_index :instances, :uri_scheme
    end

    unless index_exists?(:instances, :api_key)
      add_index :instances, :api_key, unique: true
    end
  end
end
