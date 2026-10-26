class InstanceSerializer < BaseSerializer
  attributes :id, :api_key, :uri_scheme, :updated_at,
             :get_started_dismissed, :quota_exceeded,
             :revenue_collection_enabled


  # Lists pass `icons:` from one ProjectIcons.for call so each row costs no queries.
  def build(icons: nil, **)
    h = super()
    h["production"] = ProjectSerializer.serialize(record.production)
    h["test"] = ProjectSerializer.serialize(record.test)
    h["hash_id"] = record.hashid
    h["icon_url"] = (icons || ProjectIcons.for([record]))[record.id]
    h["analytics_retention"] = analytics_retention
    h
  end

  private

  def analytics_retention
    policy = Analytics::RetentionPolicy.for(record)
    {
      "plan" => policy.plan.to_s,
      "queryable_days" => policy.queryable_days,
      "cold_after_days" => policy.hot_days,
      "can_query_cold" => policy.can_query_cold,
      "raw_max_days" => Analytics::Config::RAW_MAX_RANGE_DAYS,
      "raw_counter_max_days" => Analytics::Config::RAW_COUNTER_MAX_RANGE_DAYS
    }
  end
end
