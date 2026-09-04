# frozen_string_literal: true

module Api
  module V1
    module Analytics
      class OverviewController < BaseController
        def key_metrics
          result = ::Analytics::OverviewStatsService.key_metrics(
            @project.id,
            start_date: parsed_start_date,
            end_date: parsed_end_date,
            platform: platform_filter
          )
          render json: result, status: :ok
        end

        def key_metric_series
          unless params[:metric].present?
            return render json: { error: 'metric parameter is required' }, status: :bad_request
          end
          validate_enum!(:metric, allowed: ::Analytics::OverviewStatsService::KEY_METRIC_SOURCES.keys)
          return if performed?

          result = ::Analytics::OverviewStatsService.key_metric_series(
            @project.id,
            metric: params[:metric],
            start_date: parsed_start_date,
            end_date: parsed_end_date,
            platform: platform_filter
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
          result = ::Analytics::OverviewStatsService.user_trends(
            @project.id,
            start_date: parsed_start_date,
            end_date: parsed_end_date,
            platform: platform_filter,
            cutoff: retention_policy.queryable_cutoff_date
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
      end
    end
  end
end
