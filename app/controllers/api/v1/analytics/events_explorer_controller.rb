# frozen_string_literal: true

module Api
  module V1
    module Analytics
      class EventsExplorerController < BaseController
        MAX_AGGREGATE_RANGE_DAYS = Integer(ENV.fetch('ANALYTICS_MAX_AGGREGATE_RANGE_DAYS', 90))

        HEAVY_FILTER_OPERATORS = %w[contains is_not not_contains].freeze

        def index
          # Cap = the plan's queryable window (free 365 / paid 730 / enterprise custom).
          return if exceeded_date_range?(retention_policy.queryable_days)

          reject_heavy_shape_in_cold!(heavy: heavy_shape_requested?)
          return if invalid_cursor?
          validate_enum!(:sort_by, allowed: ::Analytics::EventsQueryService::SORTABLE_COLUMNS)
          return if performed?
          validate_enum!(:sort_order, allowed: %w[asc desc])
          return if performed?

          # The aggregate count can't run cheaply past the aggregate cap (no rollups
          # yet), so drop it beyond that range even though the row list is allowed —
          # total_count may be null per contract.
          include_count = params[:include_count] == 'true' &&
                          (parsed_end_date - parsed_start_date).to_i <= MAX_AGGREGATE_RANGE_DAYS

          result = ::Analytics::EventsQueryService.list(
            @project.id,
            start_date: parsed_start_time,
            end_date: parsed_end_time,
            cursor: params[:cursor],
            limit: safe_integer(:limit, default: 50, max: 200),
            sort_by: params[:sort_by],
            sort_order: params[:sort_order],
            search: params[:search],
            filters: params[:filters],
            include_count: include_count
          )

          annotate_visitor_uuids(result[:data])
          render json: result, status: :ok
        end

        def show
          event = ::Analytics::EventsQueryService.find(@project.id, event_id: params[:event_id])

          if event
            annotate_visitor_uuids([event])
            render json: { data: event }, status: :ok
          else
            render json: { error: 'Event not found' }, status: :not_found
          end
        end

        def volume
          return if exceeded_date_range?(MAX_AGGREGATE_RANGE_DAYS)
          validate_enum!(:bucket, allowed: %w[hour day week month])
          return if performed?

          reject_heavy_shape_in_cold!(heavy: heavy_shape_requested?)

          result = ::Analytics::EventsQueryService.volume(
            @project.id,
            start_date: parsed_start_time,
            end_date: parsed_end_time,
            bucket: params[:bucket],
            search: params[:search],
            filters: params[:filters],
            timezone: params[:timezone]
          )

          render json: result, status: :ok
        end

        def field_values
          unless params[:field].present?
            render json: { error: 'field parameter is required' }, status: :bad_request
            return
          end
          unless ALLOWED_FIELD_VALUES_FIELDS.include?(params[:field].to_s) ||
                 ::Analytics::EventsQueryService.user_attribute_field?(params[:field])
            render json: { error: "Invalid field: must be one of #{ALLOWED_FIELD_VALUES_FIELDS.join(', ')}, or user.<key>" },
                   status: :bad_request
            return
          end

          reject_heavy_shape_in_cold!(heavy: params[:q].present?)

          field = FIELD_ALIAS_MAP.fetch(params[:field], params[:field])
          result = ::Analytics::EventsQueryService.field_values(
            @project.id,
            field: field,
            q: params[:q],
            limit: safe_integer(:limit, default: 50, max: 200),
            cursor: params[:cursor],
            start_date: parsed_start_date,
            end_date: parsed_end_date
          )

          render json: result, status: :ok
        end

        def fields
          result = ::Analytics::EventsQueryService.fields(
            @project.id, start_date: parsed_start_date, end_date: parsed_end_date
          )
          render json: result, status: :ok
        end

        private

        # Instants, so the caller's local day boundaries survive; parsed_*_date still gates retention.
        def parsed_start_time
          @parsed_start_time ||= parse_time_param(params[:start_date]) || parsed_start_date
        end

        def parsed_end_time
          @parsed_end_time ||= parse_time_param(params[:end_date]) || parsed_end_date
        end

        # Guards must judge the caller's own calendar days: the picker offers exactly
        # queryable_days back, so reading those instants as UTC days 422s every non-UTC viewer.
        def guard_zone
          @guard_zone ||= ActiveSupport::TimeZone[params[:timezone].to_s] || ActiveSupport::TimeZone['UTC']
        end

        def parsed_start_date
          @events_start_date ||= begin
            instant = parse_time_param(params[:start_date])
            instant ? instant.in_time_zone(guard_zone).to_date : super()
          end
        end

        # end_date is exclusive, so the last included day is the one a second earlier.
        def parsed_end_date
          @events_end_date ||= begin
            instant = parse_time_param(params[:end_date])
            instant ? (instant - 1).in_time_zone(guard_zone).to_date : super()
          end
        end

        # An explicit zone is mandatory — without one the instant would depend on server TZ.
        def parse_time_param(raw)
          str = raw.to_s
          return nil unless str.match?(/(?:[zZ]|[+-]\d{2}:?\d{2})\z/)

          Time.iso8601(str)
        rescue ArgumentError
          nil
        end

        def annotate_visitor_uuids(rows)
          return unless rows.is_a?(Array) && rows.any?

          resolved = ::Analytics::VisitorUuidResolver.resolve_many(@project.id, rows.map { |r| r['visitor_id'] })
          rows.each do |row|
            row['visitor_uuid'], row['resolved_visitor_id'] = resolved[row['visitor_id'].to_i] || [nil, nil]
          end
        end

        def invalid_cursor?
          return false unless params[:cursor].present?

          json = Base64.urlsafe_decode64(params[:cursor])
          parsed = JSON.parse(json)
          unless parsed['t'].present? && parsed['id'].present?
            render json: { error: 'Invalid cursor' }, status: :bad_request
            return true
          end
          false
        rescue ArgumentError, JSON::ParserError
          render json: { error: 'Invalid cursor' }, status: :bad_request
          true
        end

        # Heavy = free-text search or a substring/negation filter operator.
        def heavy_shape_requested?
          return true if params[:search].present?

          ::Analytics::QueryHelpers.parse_filters(params[:filters]).any? do |f|
            HEAVY_FILTER_OPERATORS.include?(f['operator'].to_s)
          end
        end

        def exceeded_date_range?(max_days)
          days = (parsed_end_date - parsed_start_date).to_i
          if days > max_days
            render json: { error: "Date range cannot exceed #{max_days} days for this query", error_code: 'query_too_heavy' },
                   status: :unprocessable_entity
            true
          else
            false
          end
        end
      end
    end
  end
end
