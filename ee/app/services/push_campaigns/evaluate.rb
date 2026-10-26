module PushCampaigns
  # evaluating → frozen audience → sending, in one place.
  class Evaluate
    def self.call(campaign)
      out = Audience.freeze!(campaign)
      devices = campaign.audience_type == "segment" ? campaign.audience_devices : out[:targeted] # the manifest already counted a segment
      campaign.update!(targeted: out[:targeted], no_channel: out[:no_channel], not_found: out[:not_found], held: out[:held], waiting: out[:waiting],
                       audience_devices: devices, evaluated_at: Time.current)
      started = campaign.started_at || Time.current
      # A local-time send is released early; the clock starts at the time it was meant for.
      timed = campaign.winner_after_minutes && out[:waiting].positive?
      due = timed ? [started, campaign.scheduled_at].compact.max + campaign.winner_after_minutes.minutes : nil
      return false unless campaign.transition!(from: %w[evaluating], to: "sending", started_at: started, winner_due_at: due)

      !Deliverer.new(campaign).finish_if_done
    end
  end
end
