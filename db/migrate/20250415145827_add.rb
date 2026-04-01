class Add < ActiveRecord::Migration[7.0]
  def change
    # Add index to the created_at column in events table
    add_index :events, :created_at

    # Add index to the ip column in devices table
    add_index :devices, :ip

    # Add index to the remote_ip column in devices table
    add_index :devices, :remote_ip

    # Add index to the updated_at column in devices table
    add_index :devices, :updated_at

    # Add index to the web_visitor column in visitors table
    add_index :visitors, :web_visitor
  end
end
