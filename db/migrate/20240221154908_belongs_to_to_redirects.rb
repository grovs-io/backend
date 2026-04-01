class BelongsToToRedirects < ActiveRecord::Migration[6.1]
  def change
    add_reference :redirects, :application, foreign_key: true
    add_reference :redirects, :redirect_config, foreign_key: true
  end
end
