# frozen_string_literal: true

namespace :clickhouse do
  namespace :spill do
    desc "Reset attempts on exhausted spill rows so the drain retries them (after fixing the root cause)"
    task retry_exhausted: :environment do
      count = ClickhouseEventSpill.where("attempts >= ?", ClickhouseEventSpill::MAX_DRAIN_ATTEMPTS)
                                  .update_all(attempts: 0, last_error: nil)
      puts "Reset #{count} exhausted spill row(s); next DrainClickhouseSpillJob run will retry them."
    end

    desc "Show spill backlog: pending count, oldest row age, exhausted count"
    task status: :environment do
      pending = ClickhouseEventSpill.count
      exhausted = ClickhouseEventSpill.where("attempts >= ?", ClickhouseEventSpill::MAX_DRAIN_ATTEMPTS).count
      oldest = ClickhouseEventSpill.minimum(:spilled_at)
      puts "pending=#{pending} exhausted=#{exhausted} oldest_spilled_at=#{oldest || 'n/a'}"
    end
  end
end
