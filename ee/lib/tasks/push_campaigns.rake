# frozen_string_literal: true

namespace :push_campaigns do
  desc "Rebuild a campaign's counters from its deliveries: CAMPAIGN_ID=<id or hashid>"
  task recount: :environment do
    ref = ENV.fetch("CAMPAIGN_ID") { abort "CAMPAIGN_ID=<id or hashid> required" }
    campaign = PushCampaign.find_by(id: ref.to_s.match?(/\A\d+\z/) ? ref : nil) || PushCampaign.find_by_hashid(ref)
    abort "Campaign #{ref} not found" if campaign.nil?

    fixed = campaign.recount!
    puts fixed.any? ? "Campaign #{campaign.hashid}: fixed #{fixed.join(', ')}" : "Campaign #{campaign.hashid}: counters already exact"
  end
end
