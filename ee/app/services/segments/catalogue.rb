module Segments
  module Catalogue
    PROFILE_KEYS_LIMIT = 200
    PROFILE_KEYS_SAMPLE = 50_000
    PROFILE_KEYS_CACHE_TTL = 10.minutes

    def self.for(project)
      {
        version: 1,
        limits: {
          groups: Definition::MAX_GROUPS,
          conditions_per_group: Definition::MAX_CONDITIONS,
          filters: EventCondition::MAX_FILTERS,
          values: Quoting::MAX_VALUES,
          value_bytes: Quoting::MAX_BYTES,
          identifier_list: IdentifierList::MAX_ENTRIES
        },
        conditions: [
          { type: "event", event_types: Grovs::Events::ALL, filter_columns: EventCondition::FILTER_COLUMNS,
            filter_ops: Quoting::STRING_OPS, property_prefix: EventCondition::PROPERTY_PREFIX,
            max_window_days: EventCondition::LOOKBACK_DAYS, negatable: true },
          { type: "device", fields: DeviceCondition::FIELDS, ops: DeviceCondition::OPS, modes: DeviceCondition::MODES,
            current_window_days: DeviceCondition::CURRENT_DAYS, max_window_days: EventCondition::LOOKBACK_DAYS },
          { type: "profile", ops: ProfileCondition::OPS, property_prefix: ProfileCondition::PREFIX,
            property_keys: profile_property_keys(project) },
          { type: "first_seen", ops: FirstSeenCondition::OPS },
          { type: "identifier", ops: IdentifierCondition::OPS, valueless_ops: IdentifierCondition::VALUELESS },
          { type: "acquisition", id_fields: AcquisitionCondition::ID_FIELDS, string_fields: AcquisitionCondition::STRING_FIELDS,
            max_window_days: AcquisitionCondition::LOOKBACK_DAYS },
          { type: "purchase", enabled: project.instance.revenue_collection_enabled, purchase_types: Grovs::Purchases::TYPES,
            max_window_days: PurchaseCondition::LOOKBACK_DAYS, negatable: true }
        ]
      }
    end

    def self.profile_property_keys(project)
      Rails.cache.fetch("segments:profile_keys:#{project.id}", expires_in: PROFILE_KEYS_CACHE_TTL) do
        discover_profile_property_keys(project.id)
      end
    end
    private_class_method :profile_property_keys

    # Sampled DESC on visitor_id (sort key, monotonic), not last_seen: user_profiles has no TTL.
    def self.discover_profile_property_keys(project_id, sample: PROFILE_KEYS_SAMPLE)
      return [] unless Clickhouse.read_enabled?

      rows = Runner.read(<<~SQL)
        SELECT DISTINCT arrayJoin(JSONAllPaths(properties)) AS k
        FROM (
          SELECT properties FROM user_profiles
          WHERE project_id = #{Integer(project_id)}
          ORDER BY visitor_id DESC
          LIMIT #{Integer(sample)}
        )
        LIMIT #{PROFILE_KEYS_LIMIT}
      SQL
      rows.map { |r| r["k"] }.select { |k| Analytics::EventsQueryService.valid_property_key?(k) }
    rescue StandardError
      []
    end
    private_class_method :discover_profile_property_keys
  end
end
