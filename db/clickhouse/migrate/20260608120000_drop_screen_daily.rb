# frozen_string_literal: true

class DropScreenDaily < Clickhouse::Migration
  def up
    # A ClickHouse materialized view is a table-like object; DROP TABLE removes the
    # MV trigger. Drop the MV first (it reads session_events → screen_daily), then
    # the target table. The MV was created `TO screen_daily` (no inner table), so
    # dropping mv_screen_daily removes only the view; screen_daily is dropped next.
    execute 'DROP TABLE IF EXISTS mv_screen_daily'
    execute 'DROP TABLE IF EXISTS screen_daily'
  end
end
