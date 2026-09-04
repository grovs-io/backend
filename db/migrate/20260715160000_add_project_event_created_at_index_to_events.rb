# frozen_string_literal: true

# Composite index for residual PG paths that filter/group events by
# (project_id, event) — e.g. legacy visitor/campaign aggregations still on PG
# after the CH cutover. Existing indexes only cover project_id / created_at
# separately, so `WHERE project_id = ? AND event = ?` falls back to a heap filter.
#
# NOTE: events is a very large table. This builds CONCURRENTLY (no table lock) but
# can take a long time in production — run in a maintenance window / monitor.
class AddProjectEventCreatedAtIndexToEvents < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :events, %i[project_id event created_at],
              name: "index_events_on_project_id_and_event_and_created_at",
              algorithm: :concurrently,
              if_not_exists: true
  end
end
