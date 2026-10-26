module Api
  module V1
    module Mcp
      module Analytics
        class RetentionController < Api::V1::Analytics::RetentionController
          include McpProjectController

          before_action :reject_segment_filter
        end
      end
    end
  end
end
