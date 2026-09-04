# frozen_string_literal: true

module Clickhouse
  class Migration
    MIGRATION_FILENAME_REGEXP = /\A([0-9]+)_([_a-z0-9]*)\.rb\z/

    attr_reader :version, :name

    def initialize(connection, name, version)
      @connection = connection
      @name = name
      @version = version
    end

    def execute(sql)
      @connection.execute(sql)
    end

    def up
      raise NotImplementedError, "#{self.class}#up must be implemented"
    end

    def migrate
      announce 'migrating'
      time = Benchmark.measure { up }
      announce format("migrated (%.4fs)", time.real)
    end

    private

    def announce(message)
      text = "#{version} #{name}: #{message}"
      length = [0, 75 - text.length].max
      line = format("== %s %s", text, '=' * length)
      Rails.logger.info(line)
      $stdout.puts(line) unless Rails.env.test?
    end
  end
end
