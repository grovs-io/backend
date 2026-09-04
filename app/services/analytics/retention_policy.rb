# frozen_string_literal: true

module Analytics
  # Resolves an Instance + plan into a retention policy (free = hot window only).
  class RetentionPolicy
    attr_reader :plan, :hot_days, :queryable_days, :can_query_cold

    def self.for(instance)
      new(instance)
    end

    def self.cutoff_for(project_id)
      project = Project.find_by(id: project_id)
      return nil unless project&.instance

      self.for(project.instance).queryable_cutoff_date
    end

    def initialize(instance)
      @instance = instance
      @plan = detect_plan
      @hot_days = instance.cold_storage_days
      @can_query_cold = @plan != :free
      @queryable_days = @can_query_cold ? instance.delete_days : instance.cold_storage_days
    end

    def queryable_cutoff_date
      Date.current - queryable_days
    end

    def cold_cutoff_date
      Date.current - hot_days
    end

    private

    # Precedence mirrors SubscriptionBillingService: stripe (incl. paused) → enterprise → free.
    # Self-hosted has no billing — nothing may restrict reads below the configured delete_days.
    def detect_plan
      return :self_hosted if Grovs.self_hosted?
      return :paid if @instance.subscription
      return :enterprise if qualifying_enterprise?

      :free
    end

    # An enterprise row can stay active:true past its term; require the term to be current.
    def qualifying_enterprise?
      sub = @instance.valid_enterprise_subscription
      return false unless sub

      today = Date.current
      sub.start_date.to_date <= today && today <= sub.end_date.to_date
    end
  end
end
