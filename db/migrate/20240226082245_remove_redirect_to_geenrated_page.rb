class RemoveRedirectToGeenratedPage < ActiveRecord::Migration[6.1]
  def change
    remove_column :redirects, :redirect_to_generated_page
  end
end
