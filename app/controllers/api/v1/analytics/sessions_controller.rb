# frozen_string_literal: true

module Api
  module V1
    module Analytics
      # Explore-only sessions surface: list + detail. Not a seeded front-door view.
      class SessionsController < BaseController
        def index
          validate_enum!(:source, allowed: ::Analytics::QueryHelpers::SOURCE_CATEGORIES) if params[:source].present?
          return if performed?

          result = ::Analytics::SessionsQueryService.list(
            @project.id,
            start_date: parsed_start_date,
            end_date: parsed_end_date,
            cursor: params[:cursor],
            limit: safe_integer(:limit, default: 50, max: 200),
            filters: params[:filters],
            source: params[:source]
          )
          render json: result, status: :ok
        end

        def show
          key = ::Analytics::SessionsQueryService.decode_key(params[:session_key])
          return render(json: { error: 'Invalid session id' }, status: :bad_request) unless key

          # The key carries event_date, so gate the lookup against the plan window.
          raise ::Analytics::RetentionWindowExceeded if Date.parse(key[:event_date]) < retention_policy.queryable_cutoff_date

          result = ::Analytics::SessionsQueryService.find(
            @project.id, session_id: key[:session_id], visitor_id: key[:visitor_id], event_date: key[:event_date]
          )
          if result
            render json: result, status: :ok
          else
            render json: { error: 'Session not found' }, status: :not_found
          end
        end
      end
    end
  end
end
