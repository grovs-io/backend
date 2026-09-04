# frozen_string_literal: true

module AnalyticsMatrix
  # Independent oracle: describes one scenario and the expected PG/CH values,
  # derived from the input alone — never from production code.
  ScenarioInput = Struct.new(
    :event, :platform, :attribution, :visitor, :project, :payload_kind, :token,
    keyword_init: true
  )

  # Reopened (not a Struct.new block) so constants nest under ScenarioInput.
  class ScenarioInput
    CUSTOM_EVENTS = %w[custom screen_view].freeze

    # Columns on BOTH stores -> direct PG↔CH equality. CH-only fields
    # (campaign_id/inviter_id/sdk_generated/visitor_id) are checked in expected_ch.
    SHARED_FIELDS = %i[
      event_type platform link_id path session_id event_name
      vendor_id app_version build engagement_time tags
    ].freeze

    # Stamped on every scenario so otherwise-empty fields assert non-vacuously.
    ENGAGEMENT_TIME = 1234
    TAGS = %w[mtx-tag].freeze

    def custom_kind?
      CUSTOM_EVENTS.include?(event)
    end

    def derived_referral?
      attribution == :inviter_link &&
        visitor == :with_visitor &&
        %w[install reinstall].include?(event)
    end

    # screen_view needs the sentinel name; custom carries the token; system blank.
    def sdk_event_name
      case event
      when "screen_view" then "screen_view"
      when "custom"      then "mtx_#{token}"
      else ""
      end
    end

    # Only the columns build_event_row writes.
    def expected_pg(bind)
      {
        event:      event,
        project_id: bind.project_id,
        device_id:  bind.device_id,
        link_id:    bind.link_id,
        platform:   platform,
        path:       bind.link_path,
        session_id: token,
        event_name: sdk_event_name,
        engagement_time: ENGAGEMENT_TIME,
        tags:       TAGS
      }
    end

    # CH stores 0 (not nil) for absent ids and 0/1 for flags. inviter_id is 0
    # even on a referral-triggering install: the CH row is built pre-assignment.
    def expected_ch(bind)
      {
        event_type:    event,
        project_id:    bind.project_id,
        platform:      platform,
        link_id:       bind.link_id.to_i,
        path:          bind.link_path.to_s,
        campaign_id:   bind.campaign_id.to_i,
        sdk_generated: bind.sdk_generated ? 1 : 0,
        inviter_id:    0,
        visitor_id:    bind.visitor&.id || 0,
        engagement_time: ENGAGEMENT_TIME,
        tags:          TAGS,
        session_id:    token,
        event_name:    sdk_event_name
      }
    end
  end
end
