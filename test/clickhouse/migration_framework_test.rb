# frozen_string_literal: true

require 'test_helper'

# Tests for the ClickHouse migration framework: SchemaMigration, Migration, and Migrator.
# Uses a temporary migrations directory with inline migration files to avoid
# coupling to the real schema migrations.
class ClickhouseMigrationFrameworkTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  setup do
    skip 'ClickHouse not available' unless ClickhouseTestHelper.available?
    # Hermetic isolation: a dedicated EMPTY database holding ONLY schema_migrations.
    # We deliberately do NOT go through skip_unless_clickhouse!/ensure_tables! (which
    # would create the real CH tables in this db). This test wipes and recreates
    # schema_migrations; doing that in a db that also holds the real tables corrupts the
    # shared ensure_tables! state, so a later re-migration runs the real migrations
    # against already-existing tables and fails (surfaced only under the combined
    # core+EE `test:full` run). Keeping this db table-free makes the test self-contained.
    @restore_database = Clickhouse.default_database
    ClickhouseTestHelper.use_database!("#{ClickhouseTestHelper.base_database}_ch_migration_framework")
    @conn = Clickhouse.connection
    # Drop and recreate the schema_migrations table for a clean slate.
    @conn.execute("DROP TABLE IF EXISTS schema_migrations")
    @schema = Clickhouse::SchemaMigration.new(@conn)
    @schema.ensure_table
    # Clear any migration lock left over from a previous failed run.
    REDIS.with { |conn| conn.del(Clickhouse::Migrator::LOCK_KEY) }
  end

  teardown do
    REDIS.with { |conn| conn.del(Clickhouse::Migrator::LOCK_KEY) }
    # Restore the connection to the worker's base (real-tables) database so the next
    # test class starts from a clean, consistent connection.
    ClickhouseTestHelper.use_database!(ClickhouseTestHelper.base_database) if @restore_database
  end

  # ===========================================================================
  # SchemaMigration
  # ===========================================================================

  test "ensure_table is idempotent" do
    # Already created in setup — calling again should not raise.
    assert_nothing_raised { @schema.ensure_table }
  end

  test "all_versions returns empty array on fresh table" do
    assert_equal [], @schema.all_versions
  end

  test "record_version persists and all_versions retrieves it" do
    @schema.record_version(1)
    @schema.record_version(3)
    assert_equal [1, 3], @schema.all_versions
  end

  test "record_version is idempotent via ReplacingMergeTree" do
    @schema.record_version(1)
    @schema.record_version(1)
    # FINAL deduplicates — should see exactly one entry.
    assert_equal [1], @schema.all_versions
  end

  # ===========================================================================
  # Migration base class
  # ===========================================================================

  test "up raises NotImplementedError by default" do
    migration = Clickhouse::Migration.new(@conn, 'TestMigration', 999)
    assert_raises(NotImplementedError) { migration.up }
  end

  test "migrate calls up and does not raise for a concrete subclass" do
    klass = Class.new(Clickhouse::Migration) do
      attr_reader :up_called
      def up
        @up_called = true
      end
    end

    migration = klass.new(@conn, 'TestMigration', 999)
    migration.migrate
    assert migration.up_called
  end

  # ===========================================================================
  # Migrator — with temporary migration files
  # ===========================================================================

  test "migrator applies pending migrations in version order" do
    Dir.mktmpdir do |dir|
      write_migration(dir, 2, 'create_beta', "execute 'SELECT 1'")
      write_migration(dir, 1, 'create_alpha', "execute 'SELECT 1'")

      migrator = Clickhouse::Migrator.new(connection: @conn, migrations_path: dir)
      migrator.migrate

      assert_equal [1, 2], @schema.all_versions
    end
  end

  test "migrator skips already-applied migrations" do
    Dir.mktmpdir do |dir|
      write_migration(dir, 1, 'create_alpha', "execute 'SELECT 1'")
      write_migration(dir, 2, 'create_beta', "execute 'SELECT 1'")

      @schema.record_version(1)

      migrator = Clickhouse::Migrator.new(connection: @conn, migrations_path: dir)
      pending = migrator.pending_migrations

      assert_equal 1, pending.size
      assert_equal 2, pending.first.version
    end
  end

  test "migrator is idempotent — second run is a no-op" do
    Dir.mktmpdir do |dir|
      write_migration(dir, 1, 'create_alpha', "execute 'SELECT 1'")

      migrator = Clickhouse::Migrator.new(connection: @conn, migrations_path: dir)
      migrator.migrate
      assert_equal [1], @schema.all_versions

      # Second run — no new migrations.
      migrator2 = Clickhouse::Migrator.new(connection: @conn, migrations_path: dir)
      migrator2.migrate
      assert_equal [1], @schema.all_versions
    end
  end

  test "migrator rejects duplicate migration versions" do
    Dir.mktmpdir do |dir|
      write_migration(dir, 1, 'create_alpha', "execute 'SELECT 1'")
      write_migration(dir, 1, 'create_beta', "execute 'SELECT 1'", filename_override: '001_create_beta.rb')

      migrator = Clickhouse::Migrator.new(connection: @conn, migrations_path: dir)
      assert_raises(Clickhouse::Migrator::DuplicateMigrationVersionError) { migrator.migrate }
    end
  end

  test "migrator rejects duplicate migration names" do
    Dir.mktmpdir do |dir|
      write_migration(dir, 1, 'create_alpha', "execute 'SELECT 1'")
      write_migration(dir, 2, 'create_alpha', "execute 'SELECT 1'")

      migrator = Clickhouse::Migrator.new(connection: @conn, migrations_path: dir)
      assert_raises(Clickhouse::Migrator::DuplicateMigrationNameError) { migrator.migrate }
    end
  end

  test "migrator raises MigrationLockError when lock is held" do
    REDIS.with { |conn| conn.set(Clickhouse::Migrator::LOCK_KEY, 'other-process', ex: 60) }

    Dir.mktmpdir do |dir|
      write_migration(dir, 1, 'create_alpha', "execute 'SELECT 1'")

      migrator = Clickhouse::Migrator.new(connection: @conn, migrations_path: dir)
      assert_raises(Clickhouse::Migrator::MigrationLockError) { migrator.migrate }
    end
  end

  test "migrator releases lock after successful migration" do
    Dir.mktmpdir do |dir|
      write_migration(dir, 1, 'create_alpha', "execute 'SELECT 1'")

      migrator = Clickhouse::Migrator.new(connection: @conn, migrations_path: dir)
      migrator.migrate

      lock_value = REDIS.with { |conn| conn.get(Clickhouse::Migrator::LOCK_KEY) }
      assert_nil lock_value, "Lock should be released after migration"
    end
  end

  test "migrator releases lock after failed migration" do
    Dir.mktmpdir do |dir|
      write_migration(dir, 1, 'create_alpha', "raise 'boom'")

      migrator = Clickhouse::Migrator.new(connection: @conn, migrations_path: dir)
      assert_raises(RuntimeError) { migrator.migrate }

      lock_value = REDIS.with { |conn| conn.get(Clickhouse::Migrator::LOCK_KEY) }
      assert_nil lock_value, "Lock should be released even after failure"
    end
  end

  test "migrator does not retry non-retryable errors" do
    call_count = 0
    Dir.mktmpdir do |dir|
      # Write a migration that tracks how many times up is called and always fails.
      File.write(File.join(dir, '001_always_fails.rb'), <<~RUBY)
        class AlwaysFails < Clickhouse::Migration
          def up
            $ch_migration_test_call_count = ($ch_migration_test_call_count || 0) + 1
            raise ClickHouse::Client::DatabaseError, "syntax error"
          end
        end
      RUBY

      $ch_migration_test_call_count = 0
      migrator = Clickhouse::Migrator.new(connection: @conn, migrations_path: dir)
      assert_raises(ClickHouse::Client::DatabaseError) { migrator.migrate }
      assert_equal 1, $ch_migration_test_call_count, "Non-retryable error should not be retried"
    end
  ensure
    $ch_migration_test_call_count = nil
  end

  test "pending_migrations returns empty when all applied" do
    Dir.mktmpdir do |dir|
      write_migration(dir, 1, 'create_alpha', "execute 'SELECT 1'")

      @schema.record_version(1)
      migrator = Clickhouse::Migrator.new(connection: @conn, migrations_path: dir)
      assert_empty migrator.pending_migrations
    end
  end

  test "pending_migrations works with empty migrations directory" do
    Dir.mktmpdir do |dir|
      migrator = Clickhouse::Migrator.new(connection: @conn, migrations_path: dir)
      assert_empty migrator.pending_migrations
    end
  end

  private

  # Write a migration file into a temp directory.
  # Each migration gets a unique class name to avoid conflicts across tests.
  def write_migration(dir, version, name, body, filename_override: nil)
    padded_version = version.to_s.rjust(3, '0')
    filename = filename_override || "#{padded_version}_#{name}.rb"
    class_name = name.camelize

    File.write(File.join(dir, filename), <<~RUBY)
      class #{class_name} < Clickhouse::Migration
        def up
          #{body}
        end
      end
    RUBY
  end
end
