# frozen_string_literal: true

namespace :clickhouse do
  namespace :test do
    desc "Drop ClickHouse databases created by Rails test runs"
    task cleanup: :environment do
      raise "Refusing to run outside test" unless Rails.env.test?

      configured_database = Clickhouse.default_database.to_s
      base_database = configured_database.sub(/_\d+\z/, "")
      unless base_database.end_with?("_test") || base_database.include?("_test_")
        raise "Refusing to clean non-test ClickHouse database prefix: #{base_database}"
      end

      dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", false))
      escaped_prefix = base_database.gsub("\\", "\\\\").gsub("'", "''")

      admin = Clickhouse.build_connection(database: "default")
      rows = admin.select_all(
        "SELECT name FROM system.databases WHERE startsWith(name, '#{escaped_prefix}')"
      )

      rows.map { |row| row["name"].to_s }.sort.each do |database|
        next unless database.start_with?(base_database)
        next unless database.match?(/\A[a-zA-Z0-9_]+\z/)
        next if %w[default system information_schema INFORMATION_SCHEMA].include?(database)

        if dry_run
          puts "Would drop ClickHouse database `#{database}`"
        else
          admin.execute("DROP DATABASE IF EXISTS `#{database}`")
          puts "Dropped ClickHouse database `#{database}`"
        end
      end
    end
  end
end
