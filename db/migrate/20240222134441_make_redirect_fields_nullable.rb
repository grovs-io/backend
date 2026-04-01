class MakeRedirectFieldsNullable < ActiveRecord::Migration[6.1]
  def change    
    change_column_null :redirects, :appstore, true
    change_column_null :redirects, :variation, true
    change_column_null :redirects, :platform, true
    change_column_null :redirects, :redirect_to_generated_page, true
  end
end
