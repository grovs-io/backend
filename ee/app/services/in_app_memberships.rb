require "digest"

# Which visitors are in a tracked segment, kept in Postgres so sync never asks ClickHouse.
module InAppMemberships
  PAGE = 5_000
  LOCK_TTL = 15.minutes.to_i

  # Compared and deleted in one step, so a lock that expired and was taken by another run is not released.
  RELEASE = "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end".freeze

  class Locked < StandardError; end

  module_function

  # The project is part of the key: two projects with the same rules have different visitors.
  def key_for(project_id, definition_hash, list_generation)
    Digest::SHA256.hexdigest("#{project_id}:#{definition_hash}:#{list_generation}")[0, 32]
  end

  # Segment keys the project refreshes: its campaigns' and its journeys', which count toward the same limit.
  def tracked_keys(project_id, except_campaign: nil)
    campaigns = InAppCampaign.active.where(project_id: project_id).where.not(audience_type: "journey").where.not(id: except_campaign)
    (campaigns.where.not(segment_key: nil).distinct.pluck(:segment_key) + journey_keys(project_id)).uniq
  end

  # A page at a time, in visitor order: nobody is removed unless a page that was read says so; `entered` hears of additions.
  def refresh(campaign, announce: true, entered: nil)
    with_lock(campaign.segment_key) do |renew|
      manifest = manifest_for(campaign)
      after = 0
      loop do
        page = members(manifest, after)
        last = page.size < PAGE
        publish(campaign, page, after: after, upto: last ? nil : page.last, entered: entered) { |ids| InAppStamps.touch_users(ids) if announce }
        renew.call
        # So the tick sees a long first population as work in progress, not as a lost job.
        campaign.update_column(:updated_at, Time.current) if campaign.status == "preparing"
        break if last

        after = page.last
      end
      # Still under the lock, so cleanup cannot take the rows before the caller has claimed them.
      yield if block_given?
    end
  end

  def manifest_for(campaign)
    definition = Segments::Definition.parse(campaign.segment_definition, cutoff_date: nil)
    Segments::Results.for(project: campaign.project, definition: definition, list_generation: campaign.segment_list_generation,
                          segment_id: campaign.segment_id, lane: :in_app)
  end

  def members(manifest, after)
    Segments::Runner.read("SELECT visitor_id AS id FROM segment_results WHERE #{Segments::Members.effective_after_sql(manifest, after)} " \
                          "ORDER BY visitor_id LIMIT #{PAGE}").map { |row| Integer(row["id"]) }
  end

  # Makes the stored visitors in (after, upto] equal to the page; changes are yielded once written, so no device syncs ahead.
  def publish(campaign, wanted, after:, upto:, entered: nil, &told)
    scope = SegmentMembership.where(project_id: campaign.project_id, segment_key: campaign.segment_key)
    kept = remove_others(scope, wanted.to_set, after, upto, &told)
    added = wanted.reject { |id| kept.include?(id) }
    return if added.empty?

    rows = added.map { |id| { visitor_id: id, segment_key: campaign.segment_key, project_id: campaign.project_id, confirmed_at: Time.current } }
    SegmentMembership.insert_all(rows, unique_by: %i[visitor_id segment_key])
    told.call(added)
    entered&.call(added)
  end

  # Read in slices, because the stored visitors past the last page may be many more than a page.
  def remove_others(scope, want, after, upto, &told)
    kept = Set.new
    loop do
      ids = scope.where(visitor_id: (after + 1)..upto).order(:visitor_id).limit(PAGE).pluck(:visitor_id)
      gone = ids.reject { |id| want.include?(id) }
      scope.where(visitor_id: gone).delete_all if gone.any?
      told.call(gone) if gone.any?
      kept.merge(ids - gone)
      return kept if ids.size < PAGE

      after = ids.last
    end
  end

  # With keys, only those are looked at; without, every stored key is, which is the nightly run's work.
  def cleanup(keys = nil)
    used = InAppCampaign.active.where.not(segment_key: nil).distinct.pluck(:segment_key) + journey_keys
    ((keys || SegmentMembership.distinct.pluck(:segment_key)) - used).each do |key|
      with_lock(key) do
        next if InAppCampaign.active.exists?(segment_key: key) || journey_keys.include?(key)

        delete_all_of(SegmentMembership.where(segment_key: key))
      end
    rescue Locked
      next
    end
  end

  # An ended journey still reads its segments while people finish it.
  def journey_keys(project_id = nil)
    scope = Journey.where(status: Journey::STATUSES - ["draft"], finished_at: nil)
    scope = scope.where(project_id: project_id) if project_id
    scope.pluck(:segment_keys).flat_map { |keys| keys.values.pluck("key") }
  end

  # By visitor, a page at a time: in_batches on this two-column key was measured at 17,000 rows a minute.
  def delete_all_of(scope)
    after = 0
    loop do
      ids = scope.where(visitor_id: (after + 1)..).order(:visitor_id).limit(PAGE).pluck(:visitor_id)
      return if ids.empty?

      scope.where(visitor_id: ids).delete_all
      after = ids.last
    end
  end

  def move(from:, to:)
    rows = SegmentMembership.where(visitor_id: from.id).pluck(:segment_key, :project_id, :confirmed_at)
    moved = rows.sort.map { |key, project, at| { visitor_id: to.id, segment_key: key, project_id: project, confirmed_at: at } }
    SegmentMembership.insert_all(moved, unique_by: %i[visitor_id segment_key]) if moved.any?
    SegmentMembership.where(visitor_id: from.id).delete_all
  end

  def with_lock(key)
    name = "in_app:membership_lock:#{key}"
    token = SecureRandom.hex(8)
    raise Locked, key unless REDIS.with { |conn| conn.set(name, token, nx: true, ex: LOCK_TTL) }

    begin
      # Called between pages, so a long refresh keeps the lock for as long as it is working.
      yield -> { REDIS.with { |conn| conn.expire(name, LOCK_TTL) if conn.get(name) == token } }
    ensure
      REDIS.with { |conn| conn.eval(RELEASE, keys: [name], argv: [token]) }
    end
  end
end
