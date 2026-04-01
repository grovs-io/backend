class ChangeAndroidShaInArray < ActiveRecord::Migration[6.1]
  def change
    add_column :android_configurations, :sha256s, :text, array: true, default: []
    remove_column :android_configurations, :sha
  end
end
