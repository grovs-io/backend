# frozen_string_literal: true

require_relative "scenario_input"

module AnalyticsMatrix
  # Pruned Cartesian product of valid scenarios. Decides WHICH cells exist;
  # expectations live on ScenarioInput.
  class MatrixGenerator
    # SDK-reachable platforms only (base_controller needs a configured app);
    # unknown/desktop + without_visitor are covered by the process_batch phase.
    PLATFORMS = %w[ios android web].freeze

    # Hardcoded wire-contract literals, NOT Grovs::Events::* — importing the prod
    # constants would send AND expect the same value, masking a renamed constant.
    # user_referred is a derived outcome, not an input.
    EVENTS = %w[
      app_open view open install reinstall time_spent reactivation screen_view custom
    ].freeze

    ATTRIBUTIONS = %i[no_link plain_link campaign_link inviter_link].freeze
    VISITORS     = %i[with_visitor without_visitor].freeze

    def initialize(project: :one)
      @project = project
    end

    def scenarios
      idx = 0
      cells.map do |event, platform, attribution, visitor|
        idx += 1
        ScenarioInput.new(
          event: event, platform: platform, attribution: attribution,
          visitor: visitor, project: @project,
          payload_kind: payload_kind_for(event), token: format("m%04d", idx)
        )
      end
    end

    private

    def cells
      EVENTS.product(PLATFORMS, ATTRIBUTIONS, VISITORS).select { |c| valid?(*c) }
    end

    def valid?(_event, _platform, attribution, visitor)
      # inviter_link needs an installer visitor.
      return false if attribution == :inviter_link && visitor == :without_visitor

      true
    end

    def payload_kind_for(event)
      ScenarioInput::CUSTOM_EVENTS.include?(event) ? :custom : :system
    end
  end
end
