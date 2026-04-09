class McpInstanceStatusSerializer
  attr_reader :instance

  def initialize(instance)
    @instance = instance
  end

  def self.serialize(record_or_collection)
    return nil if record_or_collection.nil?
    if record_or_collection.respond_to?(:map)
      record_or_collection.map { |r| new(r).build }
    else
      new(record_or_collection).build
    end
  end

  # Reusable for the standalone GET /api/v1/mcp/usage endpoint.
  def self.usage_for(instance)
    new(instance).build_usage
  end

  def build
    {
      id: instance.hashid,
      name: instance.production&.name,
      uri_scheme: instance.uri_scheme,
      production: McpProjectStatusSerializer.serialize(instance.production),
      test: McpProjectStatusSerializer.serialize(instance.test),
      configurations: {
        ios: app_configured?(Grovs::Platforms::IOS),
        android: app_configured?(Grovs::Platforms::ANDROID),
        web: app_configured?(Grovs::Platforms::WEB),
        desktop: app_configured?(Grovs::Platforms::DESKTOP)
      },
      usage: build_usage
    }
  end

  def build_usage
    current_mau = cached_current_mau
    has_subscription = instance.subscription&.active? || instance.valid_enterprise_subscription.present?

    {
      current_mau: current_mau,
      mau_limit: Grovs.free_mau_count,
      quota_exceeded: instance.quota_exceeded,
      has_subscription: has_subscription
    }
  end

  private

  def cached_current_mau
    today = Date.today
    cache_key = "mcp_mau:#{instance.id}:#{today.strftime('%Y-%m')}"

    Rails.cache.fetch(cache_key, expires_in: 10.minutes) do
      ProjectService.new.current_mau(instance)
    end
  end

  def app_configured?(platform)
    instance.applications.detect { |a| a.platform == platform }&.configuration.present? || false
  end
end
