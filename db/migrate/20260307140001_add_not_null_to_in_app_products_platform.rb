class AddNotNullToInAppProductsPlatform < ActiveRecord::Migration[7.0]
  def up
    return unless table_exists?(:in_app_products)
    change_column_null :in_app_products, :platform, false, "web"
  end

  def down
    return unless table_exists?(:in_app_products)
    change_column_null :in_app_products, :platform, true
  end
end
