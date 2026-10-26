module Api
  module V1
    module Mcp
      module Analytics
        class OverviewController < Api::V1::Analytics::OverviewController
          include McpProjectController

          before_action :reject_segment_filter
        end
      end
    end
  end
end
