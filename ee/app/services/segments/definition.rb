module Segments
  class Definition
    VERSION = 1
    MAX_GROUPS = 5
    MAX_CONDITIONS = 10
    OPERATORS = %w[and or].freeze
    TYPES = {
      "event" => EventCondition, "device" => DeviceCondition,
      "profile" => ProfileCondition, "first_seen" => FirstSeenCondition,
      "identifier" => IdentifierCondition, "acquisition" => AcquisitionCondition,
      "purchase" => PurchaseCondition
    }.freeze

    Group = Struct.new(:operator, :conditions)

    attr_reader :errors, :operator, :groups

    def self.parse(raw, cutoff_date:) = new(raw, cutoff_date)

    def initialize(raw, cutoff_date)
      @errors = []
      @cutoff_date = cutoff_date
      data = plain(raw)
      @operator = data["operator"].to_s
      @errors << { path: "version", message: "version must be #{VERSION}" } unless Quoting.strict_int(data["version"]) == VERSION
      @errors << { path: "operator", message: "operator must be and / or" } unless OPERATORS.include?(@operator)
      @groups = build_groups(data["groups"])
    end

    def valid? = @errors.empty?

    def canonical
      { "version" => VERSION, "operator" => @operator,
        "groups" => @groups.map { |g| { "operator" => g.operator, "conditions" => g.conditions.map { |c| sort_keys(c.to_h) } } } }
    end

    def digest = Digest::SHA256.hexdigest(JSON.generate(sort_keys(canonical)))

    def conditions = @groups.flat_map(&:conditions)

    def uses?(type) = conditions.any? { |c| c.to_h["type"] == type }

    private

    def plain(raw)
      hash = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
      hash.is_a?(Hash) ? hash.deep_stringify_keys : {}
    end

    def build_groups(raw)
      list = Array(raw)
      @errors << { path: "groups", message: "between 1 and #{MAX_GROUPS} groups are required" } unless list.size.between?(1, MAX_GROUPS)
      list.first(MAX_GROUPS).each_with_index.map { |g, i| build_group(g.is_a?(Hash) ? g : {}, "groups[#{i}]") }
    end

    def build_group(raw, path)
      op = raw["operator"].to_s
      @errors << { path: "#{path}.operator", message: "operator must be and / or" } unless OPERATORS.include?(op)
      list = Array(raw["conditions"])
      unless list.size.between?(1, MAX_CONDITIONS)
        @errors << { path: "#{path}.conditions", message: "between 1 and #{MAX_CONDITIONS} conditions are required" }
      end
      conditions = list.first(MAX_CONDITIONS).each_with_index.filter_map { |c, i| build_condition(c, "#{path}.conditions[#{i}]") }
      check_negatives(op, conditions, path)
      Group.new(op, conditions)
    end

    def build_condition(raw, path)
      klass = raw.is_a?(Hash) ? TYPES[raw["type"].to_s] : nil
      unless klass
        @errors << { path: path, message: "type must be one of #{TYPES.keys.join(', ')}" }
        return nil
      end
      klass.build(raw, path: path, errors: @errors, cutoff_date: @cutoff_date)
    end

    def check_negatives(group_operator, conditions, path)
      return unless conditions.any?(&:negative?)

      if group_operator != "and"
        @errors << { path: path, message: "negative conditions are only allowed in an and group" }
      elsif conditions.all?(&:negative?)
        @errors << { path: path, message: "a group with negative conditions needs at least one positive condition" }
      end
    end

    def sort_keys(value)
      case value
      when Hash then value.sort.to_h { |k, v| [k, sort_keys(v)] }
      when Array then value.map { |v| sort_keys(v) }
      else value
      end
    end
  end
end
