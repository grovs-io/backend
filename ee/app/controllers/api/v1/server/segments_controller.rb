class Api::V1::Server::SegmentsController < Api::V1::SegmentsController
  include ServerProjectController

  private

  def segment_lane = :server
end
