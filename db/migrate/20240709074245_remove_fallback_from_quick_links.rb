class RemoveFallbackFromQuickLinks < ActiveRecord::Migration[6.1]
  def change
    remove_column :quick_links, :fallback, :string
  end
end
