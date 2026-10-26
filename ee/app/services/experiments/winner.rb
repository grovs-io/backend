# Picks the variant that did better on the test share and sends it to the people waiting, as the timer asked.
module Experiments::Winner
  WAITS = [30, 60, 120, 360, 720, 1440].freeze
  BY = %w[opens conversions].freeze

  module_function

  # Each due campaign gets its own job, so a slow ClickHouse read never holds the tick.
  def due
    PushCampaign.where(status: "sent").where("waiting > 0 AND winner_due_at <= ?", Time.current).pluck(:id).each do |id|
      PushWinnerJob.perform_async(id)
    end
  end

  def send_to_rest(campaign)
    chosen = campaign.winner
    variant = chosen || pick(campaign)
    return false unless campaign.send_winner!(variant)

    # A person's choice was audited by the request that made it.
    unless chosen
      Audit.record(instance_id: campaign.project.instance_id, action: "push_campaign.winner_sent", actor: AuditActor.system(name),
                   target: Audit.target_for(campaign), changes: { "after" => { "variant" => variant, "by" => campaign.winner_by, "automatic" => true } })
    end
    PushCampaignEvaluateJob::PARALLELISM.times { |slot| PushCampaignDeliverJob.perform_async(campaign.id, slot) }
    true
  rescue Clickhouse::Unavailable => e
    Rails.logger.warn("push_winner.deferred #{campaign.id} #{e.class}")
    false
  end

  # The best rate among the variants, as CleverTap does; ties go to the earlier variant, any under MIN_PEOPLE to A.
  def pick(campaign)
    measure = campaign.winner_by == "conversions" ? "conversion_rate" : "click_rate"
    from = (campaign.started_at || campaign.created_at).to_date.iso8601
    groups = Experiments::Report.push(campaign, from: from, to: Date.current.iso8601)["groups"].select { |g| campaign.variant_ids.include?(g["id"]) }
    return "a" if groups.any? { |g| g["exposed"].to_i < Experiments::Report::MIN_PEOPLE }

    groups.max_by { |g| [g[measure].to_f, -campaign.variant_ids.index(g["id"])] }&.dig("id") || "a"
  end
end
