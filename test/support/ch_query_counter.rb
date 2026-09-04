# frozen_string_literal: true

# Counts ClickHouse queries executed within a block using
# ActiveSupport::Notifications instrumentation.
#
# The click_house-client gem instruments all queries via the
# 'sql.click_house' notification. We subscribe during the block
# and count events.
#
# Usage in tests:
#
#   include ChQueryCounter
#
#   n = count_ch_queries { Analytics::EventsQueryService.list(...) }
#   assert_equal 1, n
#
module ChQueryCounter
  # Counts ClickHouse queries executed during the block.
  #
  # Returns the total count of queries (selects + executes).
  def count_ch_queries
    counter = 0

    subscription = ActiveSupport::Notifications.subscribe('sql.click_house') do |*_args|
      counter += 1
    end

    yield

    counter
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end
end
