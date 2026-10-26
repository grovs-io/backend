require "csv"

module Segments
  module IdentifierList
    MAX_ENTRIES = 200_000
    PREVIEW_LIMIT = 100
    QUOTED_FORMULA = /\A'+[=+\-@\t\r]/
    BATCH = 10_000
    LOCK_TTL = 600
    KEEP_SUPERSEDED_FOR = 3.hours
    RELEASE_LUA = "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end".freeze

    def self.lock_key(segment_id) = "segments:identifier_upload:#{Integer(segment_id)}"

    def self.replace!(segment, identifiers)
      raise Clickhouse::Unavailable, "segments" unless Clickhouse.enabled?

      list = clean(identifiers)
      with_lock(segment.id) do |token|
        generation = SecureRandom.hex(16)
        begin
          list.each_slice(BATCH) do |slice|
            rows = slice.map { |i| { project_id: segment.project_id, segment_id: segment.id, generation: generation, identifier: i } }
            Clickhouse.with { |conn| conn.insert("segment_identifier_entries", rows) }
          rescue ClickHouse::Client::DatabaseError, *Clickhouse::TRANSPORT_ERRORS => e
            raise Clickhouse::Unavailable, "segments" if Clickhouse.availability_error?(e)

            raise
          end
          # A stalled ClickHouse call can outlive the lock TTL; re-check before publishing.
          raise UploadInProgress, "upload lost its lock" unless REDIS.with { |c| c.get(lock_key(segment.id)) } == token

          now = Time.current
          segment.update_columns(identifier_list_generation: generation, identifier_list_count: list.size,
                                 identifier_list_updated_at: now, updated_at: now)
          { generation: generation, count: list.size }
        ensure
          # Purge runs after success (old generation) or failure (orphans), never before the lock.
          PurgeSegmentIdentifierGenerationsJob.perform_in(KEEP_SUPERSEDED_FOR, segment.id)
        end
      end
    end

    def self.entries_sql(project_id:, segment_id:, generation:)
      raise ArgumentError, "bad generation" unless generation.to_s.match?(/\A\h{32}\z/)

      "SELECT identifier FROM segment_identifier_entries WHERE project_id = #{Integer(project_id)} " \
        "AND segment_id = #{Integer(segment_id)} AND generation = '#{generation}'"
    end

    def self.preview(segment, q: nil)
      return { identifiers: [], more: false } if segment.identifier_list_generation.blank?

      term = q.to_s.strip.first(100)
      search = term.empty? ? "" : " AND positionCaseInsensitiveUTF8(identifier, #{Quoting.literal(term)}) > 0"
      ids = read("#{current_entries_sql(segment)}#{search} ORDER BY identifier LIMIT #{PREVIEW_LIMIT + 1}")
      { identifiers: ids.first(PREVIEW_LIMIT), more: ids.size > PREVIEW_LIMIT }
    end

    # Quotes formula-like cells; parse_csv strips that quote, so a download re-uploads unchanged.
    def self.to_csv(segment)
      ids = read("#{current_entries_sql(segment)} ORDER BY identifier", timeout: 30)
      CSV.generate do |csv|
        csv << ["identifier"]
        ids.each { |i| csv << [i.match?(SegmentExportJob::FORMULA_PREFIX) || i.match?(QUOTED_FORMULA) ? "'#{i}" : i] }
      end
    end

    def self.current_entries_sql(segment)
      entries_sql(project_id: segment.project_id, segment_id: segment.id, generation: segment.identifier_list_generation)
    end
    private_class_method :current_entries_sql

    # A stored list is a plain scan, so a timeout means ClickHouse is struggling, not a heavy query.
    def self.read(sql, timeout: Runner::READ_TIMEOUT)
      Runner.read(sql, timeout: timeout).to_a.map { |r| r["identifier"].to_s }
    rescue Analytics::QueryTooHeavy
      raise Clickhouse::Unavailable, "segments"
    end
    private_class_method :read

    def self.parse_csv(io)
      io = io.tempfile if io.respond_to?(:tempfile)
      io.set_encoding(Encoding::UTF_8)
      rows = CSV.new(io).lazy.each_with_index.filter_map do |row, i|
        cell = row&.first.to_s
        cell = cell.delete_prefix("\uFEFF") if i.zero?
        next if i.zero? && cell.casecmp?("identifier")

        unquote(cell).presence
      end
      rows.first(MAX_ENTRIES + 1)
    rescue CSV::MalformedCSVError => e
      raise InvalidList, "file is not valid CSV: #{e.message}"
    end

    def self.unquote(value)
      value.match?(QUOTED_FORMULA) ? value.delete_prefix("'") : value
    end
    private_class_method :unquote

    def self.clean(identifiers)
      list = Array(identifiers)
      raise InvalidList, "the list needs between 1 and #{MAX_ENTRIES} identifiers" unless list.size.between?(1, MAX_ENTRIES)
      raise InvalidList, "every identifier must be a string of 1-#{Quoting::MAX_BYTES} bytes" unless list.all? { |i| i.is_a?(String) && i.bytesize.between?(1, Quoting::MAX_BYTES) }

      list.uniq
    end
    private_class_method :clean

    def self.with_lock(segment_id)
      key = lock_key(segment_id)
      token = SecureRandom.hex(16)
      raise UploadInProgress, "an identifier upload is already running" unless REDIS.with { |c| c.set(key, token, nx: true, ex: LOCK_TTL) }

      begin
        yield token
      ensure
        REDIS.with { |c| c.eval(RELEASE_LUA, keys: [key], argv: [token]) }
      end
    end
  end
end
