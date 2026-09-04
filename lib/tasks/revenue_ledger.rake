# frozen_string_literal: true

namespace :revenue_ledger do
  desc "Backfill purchase_events snapshot columns (date, visitor_id, revenue_platform). " \
       "Resumable: START_ID=<id> to resume, BATCH_SIZE=<n> (default 5000). Idempotent."
  task backfill_snapshots: :environment do
    batch_size = Integer(ENV.fetch("BATCH_SIZE", 5_000))
    start_id   = Integer(ENV.fetch("START_ID", 0))
    totals     = Hash.new(0)

    exec_update = lambda do |sql, from, to|
      ActiveRecord::Base.connection.update(
        ActiveRecord::Base.sanitize_sql_array([sql, from, to])
      )
    end

    # Scoped to rows still missing a snapshot — this runs on every enterprise deploy.
    pending = PurchaseEvent.where(
      "purchase_events.date IS NULL " \
      "OR (purchase_events.processed AND purchase_events.visitor_id IS NULL AND purchase_events.device_id IS NOT NULL) " \
      "OR (purchase_events.processed AND purchase_events.revenue_platform IS NULL)"
    )

    pending.where(id: start_id..).in_batches(of: batch_size) do |batch|
      from, to = batch.ids.minmax

      totals[:dates] += batch.where(date: nil).update_all("date = created_at")

      # Snapshots only for processed rows — unprocessed rows get theirs at processing time.
      totals[:visitors] += exec_update.call(<<~SQL, from, to)
        UPDATE purchase_events pe SET visitor_id = v.id
        FROM visitors v
        WHERE v.device_id = pe.device_id
          AND v.project_id = pe.project_id
          AND pe.id BETWEEN ? AND ?
          AND pe.processed AND pe.visitor_id IS NULL AND pe.device_id IS NOT NULL
      SQL

      # Best-effort platform reconstruction using TODAY's rules (store_source, else current
      # device platform, else web) — historical reattribution moves and later device-platform
      # changes are unreconstructible: documented parity tolerance.
      totals[:platforms] += exec_update.call(<<~SQL, from, to)
        UPDATE purchase_events pe SET revenue_platform = CASE
          WHEN pe.store_source = 'apple'  THEN 'ios'
          WHEN pe.store_source = 'google' THEN 'android'
          ELSE COALESCE(
            (SELECT CASE WHEN d.platform IN ('ios', 'android') THEN d.platform ELSE 'web' END
             FROM devices d WHERE d.id = pe.device_id),
            'web')
        END
        WHERE pe.id BETWEEN ? AND ?
          AND pe.processed AND pe.revenue_platform IS NULL
      SQL

      puts "revenue_ledger:backfill_snapshots through id #{to} — #{totals.inspect}"
    end

    unresolved = PurchaseEvent.where(processed: true, visitor_id: nil).where.not(device_id: nil).count
    puts "DONE #{totals.inspect}"
    puts "verify: processed rows with a device but no visitor: #{unresolved} (device no longer maps to a visitor)"
    puts "verify: rows with NULL date: #{PurchaseEvent.where(date: nil).count} (must be 0)"
    puts "verify: processed rows with NULL revenue_platform: #{PurchaseEvent.where(processed: true, revenue_platform: nil).count} (must be 0)"
  end
end
