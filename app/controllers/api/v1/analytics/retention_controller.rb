# frozen_string_literal: true

module Api
  module V1
    module Analytics
      class RetentionController < BaseController
        def summary
          validate_enum!(:granularity, allowed: %w[weekly monthly])
          return if performed?

          result = ::Analytics::RetentionService.summary(
            @project.id,
            granularity: params.fetch(:granularity, 'weekly'),
            platform: platform_filter,
            start_date: parsed_start_date,
            end_date: parsed_end_date,
            filters: params[:filters] || []
          )
          render json: result, status: :ok
        end
      end
    end
  end
end
