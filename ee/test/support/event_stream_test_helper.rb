# Tests never touch DNS; SSRF tests swap in a private answer explicitly.
EventStream::HostGuard.resolver = ->(_host) { ["203.0.113.10"] }

module EventStreamTestHelper
  def outbox_ts(time) = EventStream::Outbox.format_ts(time)

  def insert_outbox_events(rows)
    Clickhouse.with do |conn|
      conn.insert("events_outbox", rows.map do |row|
        at = outbox_ts(row.fetch(:outbox_at))
        { created_at: at, ingested_at: at }.merge(row).merge(outbox_at: at)
      end)
    end
  end

  def insert_outbox_purchases(rows)
    Clickhouse.with do |conn|
      conn.insert("purchase_events_outbox", rows.map do |row|
        at = outbox_ts(row.fetch(:outbox_at))
        key = "#{row[:transaction_id]}:#{row[:event_type]}:#{(row.fetch(:outbox_at).to_f * 1000).to_i}"
        { purchase_date: at, created_at: at, purchase_key: key }.merge(row).merge(outbox_at: at)
      end)
    end
  end

  def with_resolver(addresses)
    previous = EventStream::HostGuard.resolver
    EventStream::HostGuard.resolver = ->(_host) { addresses }
    yield
  ensure
    EventStream::HostGuard.resolver = previous
  end

  def with_self_hosted
    previous = ENV.fetch("GROVS_SELF_HOSTED", nil)
    ENV["GROVS_SELF_HOSTED"] = "true"
    yield
  ensure
    ENV["GROVS_SELF_HOSTED"] = previous
  end
end
