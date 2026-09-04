# frozen_string_literal: true

module Api
  module V1
    module Concerns
      # Rejects a ClickHouse-backed analytics read that predates the plan's retention window.
      module AnalyticsRetentionGate
        extend ActiveSupport::Concern

        RETENTION_ERROR = {
          error: "This date range is outside your plan's data retention. Upgrade to access older analytics.",
          error_code: 'retention_window_exceeded'
        }.freeze

        # Matches the default every gated controller applies when start_date is absent.
        DEFAULT_START_DAYS = 30

        included do
          rescue_from ::Analytics::RetentionWindowExceeded, with: :render_retention_window_exceeded
        end

        private

        # Deliberately not the revenue ledger: that reads Postgres, so it never limits retention.
        def clickhouse_backed_read?
          Clickhouse.analytics_rollups_read_enabled?
        end

        def enforce_ch_retention_window!
          return unless clickhouse_backed_read?

          raise ::Analytics::RetentionWindowExceeded if retention_window_exceeded?
        end

        # Lets a service reuse this request's policy instead of re-deriving it per call.
        def retention_cutoff
          return nil unless clickhouse_backed_read?

          retention_policy.queryable_cutoff_date
        end

        # Raise a derived start_date to the cutoff, for reads that take no start_date param.
        def retention_floor(date)
          return date unless clickhouse_backed_read?

          [date, retention_policy.queryable_cutoff_date].max
        end

        def retention_window_exceeded?
          start_date = DateParamParser.call(params[:start_date], default: Date.current - DEFAULT_START_DAYS)
          start_date.to_date < retention_policy.queryable_cutoff_date
        end

        def retention_policy
          @retention_policy ||= ::Analytics::RetentionPolicy.for(@project.instance)
        end

        def render_retention_window_exceeded
          render json: RETENTION_ERROR, status: :unprocessable_entity
        end
      end
    end
  end
end
