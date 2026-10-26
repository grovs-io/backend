module Api
  module V1
    module Mcp
      module Analytics
        class EventsExplorerController < Api::V1::Analytics::EventsExplorerController
          include McpProjectController

          before_action :reject_segment_filter
          before_action :reject_identity_field, only: :field_values

          private

          def reject_identity_field
            field = params[:field].presence
            return unless field && McpIdentityPolicy.blocked?(field, builtin: ALLOWED_FIELD_VALUES_FIELDS)

            render_field_not_allowed(field)
          end
        end
      end
    end
  end
end
