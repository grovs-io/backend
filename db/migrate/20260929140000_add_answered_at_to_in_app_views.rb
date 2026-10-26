class AddAnsweredAtToInAppViews < ActiveRecord::Migration[8.1]
  # Set once the person has answered the campaign's question, so no device of theirs is asked again.
  def change
    add_column :in_app_views, :answered_at, :datetime
  end
end
