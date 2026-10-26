module McpQuotaWarning
  QUOTA_WARNING = begin
    msg = "Your Grovs usage has exceeded the free tier limit. Your deep links are not working."
    host = ENV["REACT_HOST"]
    if host.present?
      protocol = ENV.fetch("REACT_HOST_PROTOCOL", "https://")
      msg += " Subscribe at #{protocol}#{host} to restore service."
    end
    msg.freeze
  end

  private

  # Overrides render so the warning rides on every JSON hash without re-parsing the body.
  def render(options = nil, *args, &block)
    instance = @instance || @project&.instance
    if options.is_a?(Hash) && options[:json].is_a?(Hash) && instance&.quota_exceeded
      options[:json] = options[:json].merge(_warning: QUOTA_WARNING)
    end
    super
  end
end
