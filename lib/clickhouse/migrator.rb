# frozen_string_literal: true

require 'benchmark'

module Clickhouse
  class Migrator
    MAX_RETRY_ATTEMPTS = 3
    BASE_RETRY_SLEEP_SECONDS = 5
    LOCK_KEY = 'clickhouse:migration_lock'
    LOCK_TTL = 300 # 5 minutes

    MigrationProxy = Struct.new(:name, :version, :filename, keyword_init: true) do
      # remove_const + load, exactly as Rails' MigrationProxy does. require is idempotent,
      # so after a Zeitwerk reload of Clickhouse::Migration the class stays bound to the OLD
      # constant; plain load would then re-open it and raise superclass mismatch.
      def load_migration(connection)
        Object.send(:remove_const, name) if Object.const_defined?(name, false)
        load filename
        klass = Object.const_get(name)
        unless klass < Clickhouse::Migration
          raise "#{name} (from #{filename}) is not a Clickhouse::Migration subclass"
        end

        klass.new(connection, name, version)
      end
    end

    class DuplicateMigrationVersionError < StandardError; end
    class DuplicateMigrationNameError < StandardError; end
    class MigrationLockError < StandardError; end

    def initialize(connection: nil, migrations_path: nil)
      @connection = connection || Clickhouse.connection
      @migrations_path = migrations_path || Rails.root.join('db/clickhouse/migrate')
      @schema_migration = SchemaMigration.new(@connection)
    end

    def migrate
      with_lock do
        @schema_migration.ensure_table
        pending = pending_migrations
        if pending.empty?
          log "ClickHouse schema is up to date"
          return
        end

        pending.each { |proxy| run_migration(proxy) }
        log "Applied #{pending.size} migration(s)"
      end
    end

    def pending_migrations
      @schema_migration.ensure_table
      applied = @schema_migration.all_versions
      all_migrations.reject { |m| applied.include?(m.version) }
    end

    private

    def all_migrations
      files = Dir[File.join(@migrations_path, '[0-9]*_*.rb')]
      migrations = files.map do |file|
        basename = File.basename(file)
        match = basename.match(Clickhouse::Migration::MIGRATION_FILENAME_REGEXP)
        raise "Invalid migration filename: #{basename}" unless match

        MigrationProxy.new(
          version: match[1].to_i,
          name: match[2].camelize, # create_mv_foo → CreateMvFoo (not CreateMVFoo)
          filename: file
        )
      end

      validate!(migrations)
      migrations.sort_by(&:version)
    end

    def validate!(migrations)
      by_version = migrations.group_by(&:version)
      dup_version = by_version.find { |_, v| v.length > 1 }
      raise DuplicateMigrationVersionError, "Duplicate version: #{dup_version[0]}" if dup_version

      by_name = migrations.group_by(&:name)
      dup_name = by_name.find { |_, v| v.length > 1 }
      raise DuplicateMigrationNameError, "Duplicate name: #{dup_name[0]}" if dup_name
    end

    def run_migration(proxy)
      migration = proxy.load_migration(@connection)
      with_retry(migration) do
        migration.migrate
      end
      @schema_migration.record_version(proxy.version)
    end

    # Errors worth retrying — transient network/connection failures only.
    # ClickHouse::Client::DatabaseError (syntax errors, schema mismatches)
    # are permanent and retrying just wastes ~35s of exponential backoff.
    RETRYABLE_ERRORS = [
      Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ETIMEDOUT,
      Net::OpenTimeout, Net::ReadTimeout, SocketError, IOError
    ].freeze

    def with_retry(migration)
      attempts = 0
      begin
        attempts += 1
        yield
      rescue *RETRYABLE_ERRORS => e
        if attempts < MAX_RETRY_ATTEMPTS
          sleep_seconds = (BASE_RETRY_SLEEP_SECONDS * (2**(attempts - 1))) + rand
          log "Migration #{migration.name} (#{migration.version}) failed " \
              "(attempt #{attempts}/#{MAX_RETRY_ATTEMPTS}): #{e.message}. " \
              "Retrying in #{sleep_seconds.round(2)}s...", level: :warn
          sleep(sleep_seconds)
          retry
        end
        raise
      end
    end

    # Atomically delete the lock only if we still own it.
    # Prevents deleting a lock that was re-acquired by another process
    # after our TTL expired.
    UNLOCK_SCRIPT = <<~LUA
      if redis.call("get", KEYS[1]) == ARGV[1] then
        return redis.call("del", KEYS[1])
      else
        return 0
      end
    LUA

    def with_lock
      token = "#{Process.pid}:#{SecureRandom.hex(8)}"
      acquired = REDIS.with do |conn|
        conn.set(LOCK_KEY, token, nx: true, ex: LOCK_TTL)
      end
      raise MigrationLockError, "Another migration is running (lock key: #{LOCK_KEY})" unless acquired

      yield
    ensure
      # Redis EVAL runs a Lua script server-side for atomic check-and-delete.
      # This is the standard safe-unlock pattern — NOT arbitrary code execution.
      if acquired
        REDIS.with { |conn| conn.eval(UNLOCK_SCRIPT, keys: [LOCK_KEY], argv: [token]) }
      end
    end

    def log(message, level: :info)
      Rails.logger.public_send(level, message)
      $stdout.puts(message) unless Rails.env.test?
    end
  end
end
