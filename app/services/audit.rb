# Core entry point for the audit trail; recording lives in ee/ and every call is a no-op without it.
module Audit
  FILTERED = "[FILTERED]".freeze
  EXCLUDED_DIFF_KEYS = %w[updated_at created_at].freeze

  module_function

  def record(**kwargs)
    return nil unless defined?(AuditEvent)

    AuditEvent.record(**kwargs)
  end

  def record_for_user(**kwargs)
    return [] unless defined?(AuditEvent)

    AuditEvent.record_for_user(**kwargs)
  end

  def target_for(record)
    { "type" => record.class.name.underscore, "id" => record.id }
  end

  def diff(record)
    before = {}
    after = {}
    record.saved_changes.each do |attr, (old, new)|
      next if EXCLUDED_DIFF_KEYS.include?(attr)

      before[attr] = old
      after[attr] = new
    end
    redact({ "before" => before, "after" => after })
  end

  def redact(hash)
    filter.filter(hash)
  end

  def filter
    @filter ||= ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters, mask: FILTERED)
  end
end
