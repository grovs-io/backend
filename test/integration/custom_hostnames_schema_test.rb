require "test_helper"

# Per-table strict schema lock for `custom_hostnames`. The general SchemaDriftTest
# only catches table-level drift (its docstring explicitly disclaims column /
# index / CHECK coverage). The custom-domains flow is structurally fragile to
# missing columns or indexes: the composite unique index on (project_id, purpose)
# is the only thing preventing two primary rows on one project; the SSL
# validation TXT columns gate zero-downtime migration; the purpose column has a
# CHECK that's the model's only enum guarantee. Any one of these silently
# missing from schema.rb (because db:migrate ran against a dirty dev DB and the
# committed schema regressed) would let production diverge from what the tests
# pass against.
#
# Parses schema.rb as text so this stays a fast unit test — no DB / migrate run.
# Trade-off: this won't catch drift between schema.rb and the live PG schema; the
# CI "drop → migrate → diff" gate recommended in schema_drift_test.rb is the
# authoritative cross-check for that.
class CustomHostnamesSchemaTest < ActiveSupport::TestCase
  SCHEMA = File.read(Rails.root.join("db/schema.rb"))

  # Extract the `create_table "custom_hostnames" ... end` block exactly once.
  TABLE_BLOCK = SCHEMA[/create_table\s+"custom_hostnames".*?^  end$/m] || ""

  REQUIRED_COLUMNS = {
    # column name => Rails dump fragment that must appear inside the table block.
    # Matches the literal `t.<type> "<name>"` line plus any required modifiers.
    "hostname"                 => /t\.string\s+"hostname",\s+null:\s+false/,
    "project_id"               => /t\.bigint\s+"project_id",\s+null:\s+false/,
    "domain_id"                => /t\.bigint\s+"domain_id",\s+null:\s+false/,
    "purpose"                  => /t\.string\s+"purpose",\s+default:\s+"primary",\s+null:\s+false/,
    "source"                   => /t\.string\s+"source",\s+default:\s+"saas",\s+null:\s+false/,
    "status"                   => /t\.string\s+"status",\s+default:\s+"provisioning",\s+null:\s+false/,
    "ssl_method"                       => /t\.string\s+"ssl_method"/,
    "ssl_validation_txt_records"       => /t\.jsonb\s+"ssl_validation_txt_records",\s+default:\s+\[\],\s+null:\s+false/,
    "ownership_verification_txt_name"  => /t\.string\s+"ownership_verification_txt_name"/,
    "ownership_verification_txt_value" => /t\.string\s+"ownership_verification_txt_value"/
  }.freeze

  REQUIRED_INDEXES = [
    # The composite unique index added by 20260601101122; replaces the old
    # single-column unique on project_id. If schema.rb regresses to the old
    # index, the migration-purpose flow silently breaks (a project couldn't
    # hold both primary and migration rows).
    /index.*"project_id",\s*"purpose".*unique:\s*true/,
    # Global hostname uniqueness — the only line of defense against
    # cross-project hostname collisions in the DB.
    /index.*"hostname".*unique:\s*true/
  ].freeze

  test "custom_hostnames table is present in schema.rb" do
    assert_not_empty TABLE_BLOCK,
                     "schema.rb is missing the custom_hostnames create_table block; " \
                     "did db:schema:dump run against a DB without this branch's migrations?"
  end

  test "every required custom_hostnames column is present in schema.rb" do
    missing = REQUIRED_COLUMNS.reject { |_, pattern| TABLE_BLOCK.match?(pattern) }.keys
    assert_empty missing,
                 "schema.rb has drifted — missing columns on custom_hostnames:\n" \
                 "  #{missing.join("\n  ")}\n\n" \
                 "Either a migration is not present in db/migrate/, or db:schema:dump ran\n" \
                 "before applying the migration. Reset schema.rb from main and re-migrate."
  end

  test "composite unique index on (project_id, purpose) is present in schema.rb" do
    composite = REQUIRED_INDEXES.first
    assert TABLE_BLOCK.match?(composite),
           "schema.rb is missing the composite unique index on (project_id, purpose). " \
           "If the old single-column unique on project_id is back, two purposes per project " \
           "can't coexist. Check 20260601101122_replace_custom_hostnames_project_unique_index."
  end

  test "global unique index on hostname is present in schema.rb" do
    assert TABLE_BLOCK.match?(REQUIRED_INDEXES.last),
           "schema.rb is missing the unique index on custom_hostnames.hostname — " \
           "cross-project hostname collisions would no longer be DB-enforced."
  end

  test "purpose CHECK constraint enumerates exactly primary and migration" do
    # The CHECK is the DB-side enum guarantee; the model only validates the new
    # set, so a missing CHECK would let a raw SQL insert poison the table.
    # PG dumps the allowed values as single-quoted SQL literals inside the
    # constraint expression (e.g. `'primary'::character varying::text`).
    constraint_line = TABLE_BLOCK[/t\.check_constraint[^\n]*custom_hostnames_purpose_check[^\n]*/]
    assert constraint_line, "schema.rb is missing the custom_hostnames_purpose_check CHECK constraint"
    assert_includes constraint_line, "'primary'",
                    "purpose CHECK constraint must enumerate 'primary' as an allowed value"
    assert_includes constraint_line, "'migration'",
                    "purpose CHECK constraint must enumerate 'migration' as an allowed value"
  end

  test "the dropped legacy scalar ssl_validation_txt_name/value columns are NOT in schema.rb" do
    # Specific anti-regression: 20260602120000 dropped these columns in favor of
    # ssl_validation_txt_records (JSONB array). If they come back via a rolled-back
    # or parallel-branch migration, code might silently start writing only the first
    # CA's TXT record again — the exact bug the array column was added to fix.
    assert_no_match(/t\.string\s+"ssl_validation_txt_name"/, TABLE_BLOCK,
                 "ssl_validation_txt_name is back in schema.rb — collapses multi-CA dual issuance to one record")
    assert_no_match(/t\.string\s+"ssl_validation_txt_value"/, TABLE_BLOCK,
                 "ssl_validation_txt_value is back in schema.rb — see ssl_validation_txt_records")
  end

  test "the stale single-column unique index on project_id is NOT in schema.rb" do
    # Specific anti-regression: 20260601101122 removed this index. If it ever
    # comes back (a botched rollback, or a parallel-branch migration restoring
    # it), a project can no longer hold both primary and migration rows.
    assert_no_match(/index\s+\["project_id"\],\s+name:\s+"index_custom_hostnames_on_project_id",\s+unique:\s+true/,
                 TABLE_BLOCK,
                 "the pre-purpose unique index on project_id is back in schema.rb — " \
                 "this blocks primary+migration coexistence")
  end
end
