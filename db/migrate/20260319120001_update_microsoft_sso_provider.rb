class UpdateMicrosoftSsoProvider < ActiveRecord::Migration[7.1]
  def up
    User.where(provider: "microsoft_office365").update_all(provider: "microsoft_graph")
  end

  def down
    User.where(provider: "microsoft_graph").update_all(provider: "microsoft_office365")
  end
end
