module PushCampaigns
  class ApiCreate
    SEGMENT_PER_MINUTE = 10
    CAMPAIGNS_PER_MINUTE = 600
    RECIPIENTS_PER_MINUTE = 100_000
    WINDOW = 60
    # Atomic, so a key that expires between calls can never come back without a TTL.
    CHARGE = <<~LUA.freeze
      local n = redis.call("INCRBY", KEYS[1], ARGV[1])
      if redis.call("TTL", KEYS[1]) < 0 then redis.call("EXPIRE", KEYS[1], ARGV[2]) end
      return n
    LUA
    REFUND = <<~LUA.freeze
      if redis.call("EXISTS", KEYS[1]) == 1 then return redis.call("DECRBY", KEYS[1], ARGV[1]) end
      return 0
    LUA

    def self.call(project:, params:) = new(project, params).call

    def initialize(project, params)
      @project = project
      @p = (params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h).deep_symbolize_keys
    end

    # Everything that can be refused is checked before the budget is charged and the row is written.
    def call
      campaign = build
      attrs = Schedule.parse(@p)
      attrs.merge!(campaign.segment_snapshot_attrs) if campaign.audience_type == "segment"
      to = attrs.key?(:scheduled_at) ? "scheduled" : "evaluating"
      campaign.assign_attributes(status: to, started_at: (Time.current if to == "evaluating"), **attrs)
      raise PushCampaign::Invalid, campaign.errors.full_messages.join(", ") unless campaign.valid?

      budget!(campaign)
      campaign.save!
      audit(campaign, "push_campaign.created", "name" => campaign.name, "audience_type" => campaign.audience_type)
      audit(campaign, "push_campaign.scheduled", "scheduled_at" => campaign.scheduled_at, "recipients" => campaign.recipients.size)
      PushCampaignEvaluateJob.perform_async(campaign.id) if to == "evaluating"
      campaign
    rescue Schedule::Invalid => e
      raise PushCampaign::Invalid, e.message
    end

    private

    def build
      audience = @p[:audience].is_a?(Hash) ? @p[:audience] : {}
      raise PushCampaign::Invalid, "data must be an object" if @p.key?(:data) && !@p[:data].is_a?(Hash)

      c = @project.push_campaigns.new(source: "api", name: @p[:name].presence || @p[:title], title: @p[:title], body: @p[:body],
                                      image_url: @p[:image_url], sound: @p[:sound], data: @p[:data] || {},
                                      audience_type: audience[:type], recipients: Array(audience[:recipients]))
      if @p[:link_id].present?
        c.link = Link.joins(:domain).find_by(id: @p[:link_id], domains: { project_id: @project.id })
        raise PushCampaign::Invalid, "Link not found" if c.link.nil?
      end
      if audience[:type] == "segment"
        c.segment = @project.segments.active.find_by_hashid(audience[:segment_id])
        raise PushCampaign::Invalid, "Segment not found" if c.segment.nil?
      end
      c
    end

    # Per-project budgets in one place; a refusal on either leaves both untouched.
    def budget!(campaign)
      key, by, limit, what = if campaign.audience_type == "segment"
                               ["push_api:segment:#{@project.id}", 1, SEGMENT_PER_MINUTE, "segment campaigns"]
                             else
                               ["push_api:recipients:#{@project.id}", campaign.recipients.size, RECIPIENTS_PER_MINUTE, "recipients"]
                             end
      charge(key, by, limit, what)
      begin
        charge("push_api:campaigns:#{@project.id}", 1, CAMPAIGNS_PER_MINUTE, "campaigns")
      rescue PushCampaign::RateLimited
        refund(key, by)
        raise
      end
    end

    def charge(key, by, limit, what)
      n = REDIS.with { |c| c.eval(CHARGE, keys: [key], argv: [by, WINDOW]) }
      return if n <= limit

      refund(key, by)
      raise PushCampaign::RateLimited, "#{what}: #{limit} per minute"
    end

    def refund(key, by) = REDIS.with { |c| c.eval(REFUND, keys: [key], argv: [by]) }

    def audit(campaign, action, after)
      Audit.record(instance_id: @project.instance_id, action: action, actor: Current.actor || AuditActor.api_key(@project.instance),
                   target: Audit.target_for(campaign), changes: { "after" => after })
    end
  end
end
