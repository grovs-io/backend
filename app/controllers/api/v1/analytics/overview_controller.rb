# frozen_string_literal: true

module Api
  module V1
    module Analytics
      class OverviewController < BaseController
        GRANULARITIES = ::Analytics::TimeBuckets::GRANULARITIES
        RAW_MAX_RANGE_DAYS = EventsExplorerController::MAX_AGGREGATE_RANGE_DAYS

        def key_metrics
          return if reject_filtered_shape?

          result = ::Analytics::OverviewStatsService.key_metrics(
            @project.id,
            start_date: parsed_start_date,
            end_date: parsed_end_date,
            platform: platform_filter,
            filters: params[:filters].presence
          )
          render json: result, status: :ok
        end

        def key_metric_series
          unless params[:metric].present?
            return render json: { error: 'metric parameter is required' }, status: :bad_request
          end
          validate_enum!(:metric, allowed: ::Analytics::OverviewStatsService::KEY_METRIC_SOURCES.keys)
          return if performed?
          validate_enum!(:granularity, allowed: GRANULARITIES)
          return if performed?
          return if reject_filtered_shape?

          result = ::Analytics::OverviewStatsService.key_metric_series(
            @project.id,
            metric: params[:metric],
            start_date: parsed_start_date,
            end_date: parsed_end_date,
            platform: platform_filter,
            filters: params[:filters].presence,
            granularity: params.fetch(:granularity, 'day')
          )
          render json: result, status: :ok
        end

        # DEPRECATED (2026-07-25): superseded by version_distribution; remove after zero-traffic check.
        def versions
          result = ::Analytics::OverviewStatsService.versions(
            @project.id,
            start_date: parsed_start_date,
            end_date: parsed_end_date,
            platform: platform_filter
          )
          render json: result, status: :ok
        end

        def user_trends
          validate_enum!(:granularity, allowed: GRANULARITIES)
          return if performed?
          return if reject_filtered_shape?(from: previous_period_start)

          result = ::Analytics::OverviewStatsService.user_trends(
            @project.id,
            start_date: parsed_start_date,
            end_date: parsed_end_date,
            platform: platform_filter,
            cutoff: retention_policy.queryable_cutoff_date,
            filters: params[:filters].presence,
            granularity: params.fetch(:granularity, 'day')
          )
          render json: result, status: :ok
        end

        # DEPRECATED (2026-07-25): remove after zero external/MCP traffic check.
        def sources_breakdown
          result = ::Analytics::OverviewStatsService.sources_breakdown(
            @project.id,
            start_date: parsed_start_date,
            end_date: parsed_end_date,
            platform: platform_filter
          )
          render json: result, status: :ok
        end

        def version_distribution
          result = ::Analytics::OverviewStatsService.version_distribution(
            @project.id,
            start_date: parsed_start_date,
            end_date: parsed_end_date,
            platform: platform_filter,
            limit: safe_integer(:limit, default: 10, max: 100),
            project: @project
          )
          render json: result, status: :ok
        end

        private

        # Non-platform filters hit raw events: 90-day cap, no heavy ops in cold storage.
        def reject_filtered_shape?(from: parsed_start_date)
          return false unless non_platform_filters?
          return true if exceeded_date_range?(RAW_MAX_RANGE_DAYS)

          reject_heavy_shape_in_cold!(heavy: heavy_shape_requested?, from: from)
          false
        end
      end
    end
  end
end
