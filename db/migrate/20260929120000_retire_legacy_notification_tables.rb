class RetireLegacyNotificationTables < ActiveRecord::Migration[8.1]
  TABLES = %i[notifications notification_messages notification_targets].freeze
  NOTE = "LEGACY, unused since 2026-09-29: the messages inbox was replaced by in-app messages. " \
         "No code reads or writes this table. Drop it in the release after the one that removed the code."

  # The tables stay one release, so an instance still running the old code during the deploy keeps working.
  def up
    # Visitors and projects are busy tables: give up after 5 seconds rather than queue traffic behind the lock.
    execute "SET LOCAL lock_timeout = '5s'"
    remove_foreign_key :notification_messages, :notifications, if_exists: true
    remove_foreign_key :notification_messages, :visitors, if_exists: true
    remove_foreign_key :notification_targets, :notifications, if_exists: true
    remove_foreign_key :notifications, :projects, if_exists: true
    TABLES.each { |table| change_table_comment(table, from: nil, to: NOTE) }
  end

  def down
    TABLES.each { |table| change_table_comment(table, from: NOTE, to: nil) }
    add_foreign_key :notifications, :projects
    add_foreign_key :notification_targets, :notifications
    add_foreign_key :notification_messages, :visitors
    add_foreign_key :notification_messages, :notifications
  end
end
