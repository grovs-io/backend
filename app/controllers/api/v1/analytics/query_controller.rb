# frozen_string_literal: true

module Api
  module V1
    module Analytics
      class QueryController < BaseController
        before_action :reject_unapplied_params

        def show
          return if exceeded_date_range?(retention_policy.queryable_days)

          query = ::Analytics::MetricQuery.build(params, start_date: parsed_start_date, end_date: parsed_end_date,
                                                        platform: platform_filter, cutoff: retention_policy.queryable_cutoff_date)
          if query.raw?
            heavy = heavy_shape_requested?
            return if exceeded_date_range?(raw_cap_days(query, heavy))

            reject_heavy_shape_in_cold!(heavy: heavy, from: query.compare ? Date.parse(query.prev_start_day) : parsed_start_date)
          end
          render json: ::Analytics::MetricQueryService.run(@project.id, query), status: :ok
        rescue ::Analytics::MetricQuery::Invalid => e
          render json: { error: e.message }, status: :bad_request
        end

        private

        def reject_unapplied_params
          return if params[:segment_id].blank? && params[:search].blank?

          render json: { error: 'segment_id and search are not supported by this endpoint', error_code: 'unsupported_filter' },
                 status: :bad_request
        end

        # Plain counters prune on event_type; uniques and negations/substrings keep the short cap.
        def raw_cap_days(query, heavy)
          query.counter? && !heavy ? ::Analytics::Config::RAW_COUNTER_MAX_RANGE_DAYS : ::Analytics::Config::RAW_MAX_RANGE_DAYS
        end
      end
    end
  end
end
