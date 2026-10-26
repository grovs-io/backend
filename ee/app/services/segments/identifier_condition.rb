module Segments
  class IdentifierCondition
    OPS = %w[is_set is_not_set is contains in_list not_in_list].freeze
    VALUELESS = %w[is_set is_not_set in_list not_in_list].freeze

    def self.build(raw, path:, errors:, cutoff_date:)
      op = raw["op"].to_s
      unless OPS.include?(op)
        errors << { path: "#{path}.op", message: "op must be one of #{OPS.join(', ')}" }
        return nil
      end
      return new("op" => op) if VALUELESS.include?(op)

      values = Quoting.clean_values(raw["value"], path: "#{path}.value", errors: errors)
      values && new("op" => op, "value" => values)
    end

    def initialize(attrs) = @attrs = attrs

    def to_h = { "type" => "identifier" }.merge(@attrs)
    def negative? = %w[is_not_set not_in_list].include?(@attrs["op"])
    def window = nil

    def rows_sql(env, idx)
      "SELECT raw_id AS visitor_id, toUInt8(#{idx}) AS ci, toUInt64(1) AS n, '' AS s FROM vmap WHERE #{clause(env)}"
    end

    def predicate(idx) = "countIf(r.ci = #{idx}) > 0"

    private

    def clause(env)
      identified = "startsWith(person_key, 'i:')"
      case @attrs["op"]
      when "is_set", "is_not_set" then identified
      when "in_list", "not_in_list" then "#{identified} AND substring(person_key, 3) IN (#{list_sql(env)})"
      else "#{identified} AND #{Quoting.string_clause('substring(person_key, 3)', @attrs['op'], @attrs['value'])}"
      end
    end

    def list_sql(env)
      if env.segment_id.nil? || env.list_generation.blank?
        raise InvalidDefinition, "#{@attrs['op']} needs a saved segment with an uploaded list"
      end

      IdentifierList.entries_sql(project_id: env.project_id, segment_id: env.segment_id, generation: env.list_generation)
    end
  end
end
