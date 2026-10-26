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
        rescue_from ::Analytics::HeavyShapeInCold, with: :render_heavy_shape_in_cold
        rescue_from ::Analytics::OverviewFilters::Unsupported do |e|
          render json: { error: e.message, error_code: 'unsupported_filter' }, status: :bad_request
        end
        rescue_from ::SegmentFilter::NotFound do
          render json: { error: 'Unknown segment' }, status: :not_found
        end
        rescue_from ::SegmentFilter::Busy do
          render json: { error: 'Too many segment queries are running; retry shortly.', error_code: 'segment_busy' },
                 status: :too_many_requests
        end
        rescue_from ::SegmentFilter::Invalid do |e|
          render json: { error: e.message, error_code: 'invalid_segment' }, status: :unprocessable_entity
        end

        FIELD_ALIAS_MAP = { 'campaign' => 'campaign_id', 'link' => 'link_id', 'visitor' => 'visitor_id' }.freeze

        ALLOWED_FIELD_VALUES_FIELDS = %w[
          event_type event_name screen_name platform app_version country city
          device_model os os_version tracking_source tracking_medium
          tracking_campaign ads_platform sdk_identifier session_id
          campaign campaign_id link link_id visitor visitor_id source language
        ].freeze

        HEAVY_FILTER_OPERATORS = %w[contains is_not not_contains].freeze

        private

        def segment_clause(column = 'visitor_id', effective: false)
          @segment_clauses ||= {}
          @segment_clauses[[column, effective]] ||= ::SegmentFilter.clause(project: @project, segment_id: params[:segment_id],
                                                                            column: column, effective: effective)
        end

        def render_query_too_heavy
          render json: {
            error: 'This query took too long or used too much memory — narrow the date range or remove a filter.',
            error_code: 'query_too_heavy'
          }, status: :unprocessable_entity
        end

        def render_heavy_shape_in_cold
          render json: {
            error: '“contains” / “is not” filters and free-text search only run on data from the last ' \
                   "#{retention_policy.hot_days} days for your plan. Narrow the range or remove them.",
            error_code: 'heavy_filter_in_cold'
          }, status: :unprocessable_entity
        end

        # Unconditional: require_clickhouse! already made CH the only source here.
        def enforce_retention_window!
          return if parsed_start_date >= retention_policy.queryable_cutoff_date

          raise ::Analytics::RetentionWindowExceeded
        end

        def reject_heavy_shape_in_cold!(heavy:, from: parsed_start_date)
          raise ::Analytics::HeavyShapeInCold, 'heavy raw query into cold storage' if heavy && from < retention_policy.cold_cutoff_date
        end

        def heavy_shape_requested?
          return true if params[:segment_id].present?
          return true if params[:search].present?

          ::Analytics::QueryHelpers.parse_filters(params[:filters]).any? do |f|
            HEAVY_FILTER_OPERATORS.include?(f['operator'].to_s)
          end
        end

        # True when the request carries any chip other than a single `platform is X`.
        def non_platform_filters?
          ::Analytics::OverviewFilters.resolve(params[:filters], platform: platform_filter).raw?
        end

        def exceeded_date_range?(max_days)
          days = (parsed_end_date - parsed_start_date).to_i
          return false if days <= max_days

          render json: { error: "Date range cannot exceed #{max_days} days for this query", error_code: 'query_too_heavy' },
                 status: :unprocessable_entity
          true
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

        # Previous-period reads start earlier, so cold guards for compare/trends judge this date.
        def previous_period_start
          parsed_start_date - (parsed_end_date - parsed_start_date).to_i - 1
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
