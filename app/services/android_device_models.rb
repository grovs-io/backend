require "csv"

# Maps Android Build.MODEL values ("SM-S928B") to marketing names
# ("Samsung Galaxy S24 Ultra") using Google's published supported-devices CSV.
#
# The table lives in a Redis hash with no TTL: a failed refresh keeps serving the
# previous table, and before the first successful refresh every lookup misses and
# the raw model passes through — the pre-mapping behavior. The first lookup that
# finds no table enqueues a refresh (once — NX lock), so a flushed Redis or a cold
# deploy self-heals on the next Android request. A scheduled job keeps it fresh.
class AndroidDeviceModels
  KEY = "android_device_models".freeze
  REFRESH_LOCK = "#{KEY}:refresh_lock".freeze

  CSV_URL = "https://storage.googleapis.com/play_public/supported_devices.csv".freeze
  EXPECTED_HEADERS = ["Retail Branding", "Marketing Name", "Device", "Model"].freeze

  # A genuine download has ~53k rows; anything much smaller is truncated or garbage.
  MIN_CSV_ROWS = 40_000
  MIN_MAPPED_MODELS = 20_000

  class << self
    def humanize(model)
      return model if model.blank?

      name = REDIS.hget(KEY, model)
      schedule_refresh if name.nil? && REDIS.hlen(KEY).zero?

      name.presence || model
    end

    # Download → decode → validate → build → atomic swap. Any failure aborts before
    # the swap, so the live table is never degraded. Returns true on success.
    def refresh!
      body = fetch_csv
      return refused("empty download") if body.blank?

      rows = parse(body)
      return refused("only #{rows.size} rows") if rows.size < MIN_CSV_ROWS

      mapping = build_mapping(rows)
      return refused("only #{mapping.size} mapped models") if mapping.size < MIN_MAPPED_MODELS

      swap_in(mapping)
      Rails.logger.info("AndroidDeviceModels: refreshed with #{mapping.size} models")
      true
    rescue StandardError => e
      refused("#{e.class}: #{e.message}")
    end

    private

    def schedule_refresh
      RefreshAndroidDeviceModelsJob.perform_async if REDIS.set(REFRESH_LOCK, "1", nx: true, ex: 600)
    end

    def fetch_csv
      response = HTTParty.get(CSV_URL, timeout: 60)
      response.success? ? response.body : nil
    end

    def parse(body)
      utf8 = body.dup.force_encoding(Encoding::UTF_16LE)
                 .encode(Encoding::UTF_8)
                 .delete_prefix("﻿")
      csv = CSV.parse(utf8, headers: true)
      raise ArgumentError, "unexpected headers: #{csv.headers.inspect}" unless csv.headers == EXPECTED_HEADERS

      csv
    end

    def build_mapping(rows)
      mapping = {}
      rows.each do |row|
        model = row["Model"]
        name = [row["Retail Branding"], row["Marketing Name"]].compact_blank.join(" ")
        next if model.blank? || row["Marketing Name"].blank? || name == model

        mapping[model] ||= name
      end
      mapping
    end

    def swap_in(mapping)
      tmp = "#{KEY}:tmp:#{SecureRandom.hex(6)}"

      REDIS.with do |conn|
        mapping.each_slice(1000) do |slice|
          conn.hset(tmp, slice.to_h)
        end
        conn.expire(tmp, 3600) # self-clean if we die before the rename
        conn.rename(tmp, KEY)
        conn.persist(KEY)
      end
    end

    def refused(reason)
      Rails.logger.error("AndroidDeviceModels: refresh refused, keeping previous table (#{reason})")
      false
    end
  end
end
