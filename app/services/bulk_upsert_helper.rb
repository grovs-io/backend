module BulkUpsertHelper
  # Pattern: only word chars, dots, parens, commas, spaces, and quoted identifiers.
  # Rejects semicolons, comments (--), subqueries, etc.
  SAFE_SQL_SET_CLAUSE = /\A[\w\s."(),=+]+\z/

  # Executes a bulk INSERT...ON CONFLICT DO UPDATE that increments metric columns.
  #
  # @param table [String] table name
  # @param rows [Array<Hash>] rows to upsert, keyed by column name
  # @param columns [Array<Symbol>] ordered column list for INSERT
  # @param conflict_keys [Array<Symbol>] columns forming the unique constraint
  # @param metric_columns [Array<Symbol>] columns to increment with COALESCE(existing, 0) + EXCLUDED
  # @param extra_conflict_sets [Array<String>] additional SET clauses for ON CONFLICT (validated against SAFE_SQL_SET_CLAUSE)
  def self.execute(table:, rows:, columns:, conflict_keys:, metric_columns:, extra_conflict_sets: [])
    return if rows.empty?

    extra_conflict_sets.each do |clause|
      unless clause.match?(SAFE_SQL_SET_CLAUSE)
        raise ArgumentError, "Unsafe extra_conflict_sets clause: #{clause.inspect}"
      end
    end

    ActiveRecord::Base.with_connection do |conn|
      quoted_table = conn.quote_table_name(table)
      quoted_columns = columns.map { |c| conn.quote_column_name(c) }
      quoted_conflict = conflict_keys.map { |c| conn.quote_column_name(c) }

      metric_set = metric_columns.to_set

      values_clause = rows.map do |row|
        values = columns.map do |col|
          if metric_set.include?(col)
            conn.quote(row[col].to_i)
          else
            conn.quote(row[col])
          end
        end
        "(#{values.join(', ')})"
      end.join(', ')

      metric_sets = metric_columns.map do |col|
        qcol = conn.quote_column_name(col)
        "#{qcol} = COALESCE(#{quoted_table}.#{qcol}, 0) + EXCLUDED.#{qcol}"
      end

      all_sets = metric_sets + extra_conflict_sets +
                 ["#{conn.quote_column_name(:updated_at)} = EXCLUDED.#{conn.quote_column_name(:updated_at)}"]

      sql = <<~SQL
        INSERT INTO #{quoted_table} (#{quoted_columns.join(', ')})
        VALUES #{values_clause}
        ON CONFLICT (#{quoted_conflict.join(', ')})
        DO UPDATE SET
          #{all_sets.join(",\n          ")}
      SQL

      conn.execute(sql)
    end
  end
end
