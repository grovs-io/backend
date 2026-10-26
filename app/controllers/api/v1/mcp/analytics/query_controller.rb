module Api
  module V1
    module Mcp
      module Analytics
        class QueryController < Api::V1::Analytics::QueryController
          include McpProjectController

          before_action :reject_identity_group_by

          private

          def reject_identity_group_by
            group_by = params[:group_by].presence
            return unless group_by && McpIdentityPolicy.blocked?(group_by, builtin: ::Analytics::MetricQuery::DIMENSIONS)

            render_field_not_allowed(group_by)
          end
        end
      end
    end
  end
end
