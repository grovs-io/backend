class AddLanguageToDevice < ActiveRecord::Migration[6.1]
  def change
    add_column :devices, :language, :string
  end
end
