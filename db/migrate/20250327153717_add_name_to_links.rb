class AddNameToLinks < ActiveRecord::Migration[7.0]
  def change
    # Add the new 'name' column
    add_column :links, :name, :string

    # Update the 'name' column with the value of 'generated_from_platform' for existing rows
    Link.find_each do |link|
      link.update_column(:name, link.generated_from_platform)
    end
  end
end
