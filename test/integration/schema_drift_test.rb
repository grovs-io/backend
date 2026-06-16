require "test_helper"

# Detects schema.rb drift: tables present in db/schema.rb that have no corresponding
# migration file in db/migrate/.
#
# This is the regression test for the issue where running `db:migrate` against a dev
# database that has migrations from OTHER branches dumps those tables into schema.rb,
# so the committed schema.rb ends up containing orphan tables. When that schema.rb gets
# checked in, fresh `db:schema:load` creates objects that production won't have after
# running this branch's migrations alone.
#
# Scope notes:
#
#   - Table-level drift IS caught here. This catches the dominant case (a parallel-branch
#     migration added a new table that got picked up by `db:migrate` in the dev DB).
#
#   - Column / index / FK / CHECK drift is NOT caught by this test. A complete check would
#     require running all migrations from scratch on a clean DB and comparing the dumped
#     schema to the committed one. That's CI infrastructure (drop test DB → migrate →
#     `db:schema:dump` → diff) rather than a Rails unit test, because reliably detecting
#     "this column has no migration" via static parsing of migration files runs into too
#     many false positives (rename_column, raw SQL, change_table, etc.).
#
#     CI gate recommendation: add a job that runs against a fresh Postgres container:
#       bundle exec rails db:drop db:create db:migrate
#       git diff --exit-code db/schema.rb
#     That step catches any column/index/FK drift that this test doesn't.
class SchemaDriftTest < ActiveSupport::TestCase
  # Tables created by gems (their own migrations live in the gem, not db/migrate/).
  # Keep this list TINY — only add things whose source is clearly a third-party gem.
  GEM_OWNED_TABLES = %w[
    rpush_apps
    rpush_feedback
    rpush_notifications
  ].freeze

  test "every table in db/schema.rb is created by some migration in db/migrate/" do
    schema_path = Rails.root.join("db/schema.rb")
    schema_content = File.read(schema_path)
    schema_tables = schema_content.scan(/create_table\s+"([^"]+)"/).flatten.uniq

    migration_tables = Dir[Rails.root.join("db/migrate/*.rb")].flat_map do |file|
      content = File.read(file)
      content.scan(/create_table\s+(?::([a-z_][a-z0-9_]*)|"([^"]+)")/i).map { |m| m.compact.first }
    end.uniq

    drift = schema_tables - migration_tables - GEM_OWNED_TABLES
    assert_empty drift,
      "db/schema.rb has tables with no backing migration in db/migrate/ (and not in the gem-owned allowlist):\n" \
      "  #{drift.join("\n  ")}\n\n" \
      "This usually means `db:migrate` ran against a dev DB that has migrations from another\n" \
      "branch. Reset: `git checkout main -- db/schema.rb`, then re-apply only the migrations\n" \
      "on this branch by hand or migrate against a clean DB.\n\n" \
      "If the table is genuinely gem-owned, add it to GEM_OWNED_TABLES in this test."
  end
end
