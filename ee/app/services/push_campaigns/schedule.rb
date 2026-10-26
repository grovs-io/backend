module PushCampaigns
  # Parses the send request's schedule fields; validation of the values lives on the model.
  module Schedule
    Invalid = Class.new(StandardError)

    module_function

    def parse(params)
      p = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
      p = p.with_indifferent_access
      if p[:scheduled_at].blank?
        raise Invalid, "local_time needs scheduled_at" if ActiveModel::Type::Boolean.new.cast(p[:local_time])

        return {}
      end

      at = begin
        Time.zone.parse(p[:scheduled_at].to_s)
      rescue ArgumentError # out-of-range parts such as month 13
        nil
      end
      raise Invalid, "scheduled_at must be an ISO 8601 time" if at.nil?

      { scheduled_at: at, local_time: ActiveModel::Type::Boolean.new.cast(p[:local_time]) || false,
        timezone: p[:timezone].presence || "UTC" }
    end
  end
end
