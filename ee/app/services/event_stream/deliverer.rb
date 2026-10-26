module EventStream
  # One loop iteration for one Destination. At-least-once: the Bookmark only moves past the contiguous accepted prefix.
  class Deliverer
    LAG_SECONDS = 15
    READ_LIMIT = 500
    GAP_MAIL_INTERVAL = 1.day
    Item = Struct.new(:body, :group_key, :pos, :cursor_at, :cursor_id, :kind)

    def initialize(destination, deadline: nil)
      @destination = destination
      @deadline = deadline
    end

    def run_once
      return :disabled unless Grovs.event_stream_enabled? && @destination.enabled? && @destination.project.instance.event_stream_enabled?

      @cutoff = Outbox.cutoff(LAG_SECONDS)
      clamp_bookmarks_to_retention!
      items = load_items
      if items.empty?
        @destination.record_idle!(cursor: @idle)
        return :idle
      end

      accepted_upto = deliver(items)
      cursor = cursor_after(items, accepted_upto).merge(@idle)
      if @last_error.nil?
        @destination.record_success!(cursor: cursor, delivered: accepted_upto)
        return :delivered
      end

      @destination.record_partial!(cursor: cursor, delivered: accepted_upto) if accepted_upto.positive? || @idle.any?
      outcome = @destination.record_failure!(@last_error)
      notify { EventStreamMailer.paused(@destination) } if outcome == :paused
      outcome == :paused ? :paused : :failed
    rescue ActiveRecord::StaleObjectError
      # A rewind or an overlapping worker moved the Bookmark first; this run's position is void.
      :stale
    end

    def self.gap_keys(destination_id)
      ["event_stream:gap_mailed:#{destination_id}", "event_stream:gap:#{destination_id}"]
    end

    private

    def events_requested? = (@destination.event_types - ["purchase"]).any?
    def purchases_requested? = @destination.event_types.include?("purchase")

    # A stream with nothing to send moves to the cutoff, so a quiet or unrequested stream never goes stale.
    def load_items
      events = events_requested? ? read_events : []
      purchases = purchases_requested? ? read_purchases : []
      @idle = {}
      @idle.merge!(events_at: @cutoff, events_id: "") if events.empty?
      @idle.merge!(purchases_at: @cutoff, purchases_id: "") if purchases.empty?

      merged = Outbox.merge_by_arrival(events, purchases, READ_LIMIT)
      bodies = EnvelopeBuilder.new(project: @destination.project, include_ip: @destination.include_ip).build_merged(merged)
      merged.each_with_index.map do |(kind, row), i|
        id = kind == :event ? row["event_id"] : row["purchase_key"]
        Item.new(bodies[i], row["device_id"].to_i, i, Outbox.parse_ts(row["outbox_at"]), id.to_s, kind)
      end
    end

    def read_events
      Outbox.read_events(project_id: @destination.project_id, after_at: @destination.events_cursor_at,
                         after_id: @destination.events_cursor_id, event_types: @destination.event_types - ["purchase"],
                         limit: READ_LIMIT, cutoff: @cutoff)
    end

    def read_purchases
      Outbox.read_purchases(project_id: @destination.project_id, after_at: @destination.purchases_cursor_at,
                            after_id: @destination.purchases_cursor_id, limit: READ_LIMIT, cutoff: @cutoff)
    end

    # Returns the count of the contiguous accepted prefix (in batch order).
    def deliver(items)
      @last_error = nil
      return deliver_one_date(items) if @destination.s3?

      webhook = adapter
      stopped_at = []
      items.group_by(&:group_key).values.each_slice(@destination.concurrency).with_index do |slice, index|
        if index.positive? && past_deadline?
          stopped_at << slice.first.first.pos
          break
        end
        send_slice(webhook, slice).each do |group, accepted, error|
          next if accepted == group.size

          @last_error ||= error
          stopped_at << group[accepted].pos
        end
      end
      stopped_at.min || items.size
    end

    def send_slice(webhook, slice)
      threads = slice.map do |group|
        Thread.new { Rails.application.executor.wrap { [group, *webhook.deliver(group.map(&:body))] } }
      end
      threads.map(&:value)
    end

    def past_deadline?
      @deadline.present? && Time.current >= @deadline
    end

    # One event date per S3 run keeps each run to a single bounded PUT, however many days a backlog spans.
    def deliver_one_date(items)
      date = Adapters::S3.event_date(items.first.body)
      run = items.take_while { |item| Adapters::S3.event_date(item.body) == date }
      accepted, error = adapter.deliver(run.map(&:body))
      @last_error = error
      accepted == run.size ? run.size : 0
    end

    def adapter
      @adapter ||= @destination.s3? ? Adapters::S3.new(@destination) : Adapters::Webhook.new(@destination, deadline: @deadline)
    end

    def cursor_after(items, count)
      cursor = {}
      return cursor if count.zero?

      accepted = items.first(count)
      last_event = accepted.reverse.find { |i| i.kind == :event }
      last_purchase = accepted.reverse.find { |i| i.kind == :purchase }
      cursor.merge!(events_at: last_event.cursor_at, events_id: last_event.cursor_id) if last_event
      cursor.merge!(purchases_at: last_purchase.cursor_at, purchases_id: last_purchase.cursor_id) if last_purchase
      cursor
    end

    def clamp_bookmarks_to_retention!
      floor = Time.current - Outbox::RETENTION_DAYS.days
      stale = {}
      stale[:events] = @destination.events_cursor_at if events_requested? && older?(@destination.events_cursor_at, floor)
      stale[:purchases] = @destination.purchases_cursor_at if purchases_requested? && older?(@destination.purchases_cursor_at, floor)
      return flush_gap if stale.empty?

      cursor = {}
      cursor.merge!(events_at: floor, events_id: "") if stale.key?(:events)
      cursor.merge!(purchases_at: floor, purchases_id: "") if stale.key?(:purchases)
      @destination.advance!(cursor)
      hold_gap(stale.values.min, floor)
      flush_gap
    end

    def hold_gap(from, to)
      gap_key = self.class.gap_keys(@destination.id).last
      REDIS.with do |redis|
        redis.multi do |tx|
          tx.hsetnx(gap_key, "from", Outbox.format_ts(from))
          tx.hset(gap_key, "to", Outbox.format_ts(to))
          tx.expire(gap_key, (Outbox::RETENTION_DAYS.days + GAP_MAIL_INTERVAL).to_i)
        end
      end
    end

    # Runs every time, so a held gap is still mailed once the Bookmark has caught up.
    def flush_gap
      mailed_key, gap_key = self.class.gap_keys(@destination.id)
      gap = REDIS.with do |redis|
        next unless redis.exists?(gap_key) && redis.set(mailed_key, "1", nx: true, ex: GAP_MAIL_INTERVAL.to_i)

        redis.multi { |tx| [tx.hgetall(gap_key), tx.del(gap_key)] }.first
      end
      return if gap.blank?

      notify { EventStreamMailer.gap(@destination, from: Outbox.parse_ts(gap["from"]), to: Outbox.parse_ts(gap["to"])) }
    end

    def older?(time, floor)
      time.present? && time < floor
    end

    # Mail must never break delivery; a lost notification is recoverable, a stuck Bookmark is not.
    def notify
      yield.deliver_now
    rescue StandardError => e
      Rails.logger.warn(message: "event_stream_mail_failed", destination_id: @destination.id, error: e.message)
    end
  end
end
