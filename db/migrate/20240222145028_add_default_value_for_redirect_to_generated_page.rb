class AddDefaultValueForRedirectToGeneratedPage < ActiveRecord::Migration[6.1]
  def change
    change_column :redirects, :redirect_to_generated_page, :boolean, default: false
  end
end
