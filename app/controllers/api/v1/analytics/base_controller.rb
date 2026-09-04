# frozen_string_literal: true

module Api
  module V1
    module Analytics
      class BaseController < Api::V1::ProjectsBaseController
        include DashboardAuthorization
        include Api::V1::Concerns::AnalyticsRetentionGate

        before_action :doorkeeper_authorize!
        before_action :authorize_and_load_project
        before_action :require_clickhouse!
        before_action :validate_date_range!
        before_action :enforce_retention_window!

        rescue_from ::Analytics::QueryTooHeavy, with: :render_query_too_heavy

        FIELD_ALIAS_MAP = { 'campaign' => 'campaign_id', 'link' => 'link_id', 'visitor' => 'visitor_id' }.freeze

        ALLOWED_FIELD_VALUES_FIELDS = %w[
          event_type event_name screen_name platform app_version country city
          device_model os os_version tracking_source tracking_medium
          tracking_campaign ads_platform sdk_identifier session_id
          campaign campaign_id link link_id visitor visitor_id
        ].freeze

        private

        def render_query_too_heavy
          render json: {
            error: 'Range too large — narrow the date range or remove a filter.',
            error_code: 'query_too_heavy'
          }, status: :unprocessable_entity
        end

        # Unconditional: require_clickhouse! already made CH the only source here.
        def enforce_retention_window!
          return if parsed_start_date >= retention_policy.queryable_cutoff_date

          raise ::Analytics::RetentionWindowExceeded
        end

        def range_enters_cold?
          parsed_start_date < retention_policy.cold_cutoff_date
        end

        def reject_heavy_shape_in_cold!(heavy:)
          raise ::Analytics::QueryTooHeavy, 'heavy raw query into cold storage' if heavy && range_enters_cold?
        end

        def parsed_start_date
          @parsed_start_date ||= DateParamParser.call(params[:start_date], default: 30.days.ago.to_date)
        end

        def parsed_end_date
          @parsed_end_date ||= DateParamParser.call(params[:end_date], default: Date.current)
        end

        def platform_filter
          params[:platform].presence
        end

        def require_clickhouse!
          return if Clickhouse.read_enabled?

          render json: { error: 'Analytics temporarily unavailable' }, status: :service_unavailable
        end

        def validate_date_range!
          return if parsed_start_date <= parsed_end_date

          render json: { error: 'start_date must be on or before end_date' }, status: :unprocessable_entity
        end

        def safe_integer(param_name, default:, max:)
          raw = params[param_name]
          return default if raw.blank?

          val = Integer(raw)
          return default if val < 1

          [val, max].min
        rescue ArgumentError, TypeError
          default
        end

        def validate_enum!(param_name, allowed:)
          raw = params[param_name]
          return if raw.blank?
          return if allowed.include?(raw.to_s)

          render json: { error: "Invalid #{param_name}: must be one of #{allowed.join(', ')}" },
                 status: :bad_request
        end
      end
    end
  end
end
