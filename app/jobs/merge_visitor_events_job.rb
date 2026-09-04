class MergeVisitorEventsJob
  include Sidekiq::Job
  # Durability via Sidekiq: ~6h of backoff, then the (replayable) Dead set
  sidekiq_options queue: :events, retry: 10

  PAIR_PREFIX = "merge_pair" # request dedup, set by DeviceService (5 min)
  LOCK_PREFIX = "merge_device_lock"
  LOCK_TTL = 300 # generous ceiling for one merge (event updates are chunked)
  RETRY_DELAY = 30 # seconds — requeue delay when a device lock is contended

  def perform(from_device_id, to_device_id, project_id)
    to_device_id = resolve_target(project_id, to_device_id)
    return if from_device_id == to_device_id

    merged = with_device_locks(from_device_id, to_device_id, project_id) do
      merge!(from_device_id, to_device_id, project_id)
    end
    return if merged

    # Lock contention is not an error — requeue instead of burning a retry
    self.class.perform_in(RETRY_DELAY, from_device_id, to_device_id, project_id)
  end

  private

  # Never merge into (and revive) a device that was itself merged away
  def resolve_target(project_id, to_device_id)
    BatchEventProcessorJob::MERGE_REMAP_MAX_HOPS.times do
      mapped = REDIS.get(BatchEventProcessorJob.merged_device_key(project_id, to_device_id))
      break if mapped.blank? || mapped.to_i == to_device_id

      to_device_id = mapped.to_i
    end
    to_device_id
  end

  def merge!(from_device_id, to_device_id, project_id)
    from_device = Device.find_by(id: from_device_id)
    to_device = Device.find_by(id: to_device_id)
    project = Project.find_by(id: project_id)

    if !from_device || !to_device || !project
      Rails.logger.warn("Project, From Device or To Device not found for merging events")
      return
    end

    # Ensure installed app exists for both devices
    [from_device, to_device].each do |device|
      InstalledApp.find_or_create_by!(device_id: device.id, project_id: project.id)
    end

    cache_keys = nil
    merged_visitor_id = nil
    survivor_visitor_id = nil

    ActiveRecord::Base.transaction do
      conn = ActiveRecord::Base.lease_connection
      conn.execute("SET LOCAL statement_timeout = '10s'")

      from_visitor = Visitor.find_by(device_id: from_device.id, project_id: project.id)
      unless from_visitor
        Rails.logger.warn("From Visitor not found for merging events, nothing to merge")
        # A prior attempt may have crashed after merging but before the breadcrumb
        write_merge_breadcrumb(project_id, from_device_id, to_device_id)
        return
      end

      to_visitor = Visitor.find_or_create_by!(device: to_device, project: project)

      # Update inviter if needed (never to to_visitor itself — no self-referral)
      if to_visitor.inviter_id.nil? && from_visitor.inviter_id.present? &&
         from_visitor.inviter_id != to_visitor.id
        to_visitor.inviter_id = from_visitor.inviter_id
        to_visitor.save!
      end

      # Merge actions, links and events in bulk
      from_device.actions.update_all(device_id: to_device.id)
      from_visitor.links.update_all(visitor_id: to_visitor.id)
      # Chunked and re-locked per batch — a multi-million-event merge can outlive LOCK_TTL.
      from_device.events.in_batches(of: 50_000, use_ranges: true) do |batch|
        batch.update_all(device_id: to_device.id, platform: to_device.platform)
        renew_device_locks(from_device_id, to_device_id, project_id)
      end

      merge_visitor_stats(from_visitor, to_visitor)

      repoint_purchase_ledger(project, from_visitor, to_visitor, from_device, to_device) do
        renew_device_locks(from_device_id, to_device_id, project_id)
      end

      repoint_device_scoped_purchase_state(from_device, to_device)

      # Transfer last-visit attribution (keep the most recent one)
      from_vlv = VisitorLastVisit.find_by(project_id: project.id, visitor_id: from_visitor.id)
      if from_vlv
        to_vlv = VisitorLastVisit.find_by(project_id: project.id, visitor_id: to_visitor.id)
        if to_vlv.nil? || from_vlv.updated_at > to_vlv.updated_at
          VisitorLastVisit.connection.execute(
            VisitorLastVisit.sanitize_sql_array([
              "INSERT INTO visitor_last_visits (project_id, visitor_id, link_id, created_at, updated_at) " \
              "VALUES (?, ?, ?, NOW(), NOW()) " \
              "ON CONFLICT (project_id, visitor_id) DO UPDATE SET link_id = EXCLUDED.link_id, updated_at = EXCLUDED.updated_at",
              project.id, to_visitor.id, from_vlv.link_id
            ])
          )
        end
        from_vlv.delete
      end

      NotificationMessage.where(visitor_id: from_visitor.id).delete_all

      repoint_referrals(from_visitor, to_visitor)

      # delete (not destroy): all dependents handled above; clear Redis cache after commit
      cache_keys = from_visitor.cache_keys_to_clear
      merged_visitor_id = from_visitor.id
      survivor_visitor_id = to_visitor.id
      # BEFORE the delete: a failed write aborts the transaction, so no visitor is left unmarked.
      write_merge_breadcrumb(project_id, from_device_id, to_device_id)
      from_visitor.delete
    end

    refresh_merge_breadcrumb(project_id, from_device_id, to_device_id)

    invalidate_visitor_cache(cache_keys)

    fold_visitor_into_survivor_in_clickhouse(project_id, merged_visitor_id, survivor_visitor_id)
  end

  # Phase 4: instead of DELETING the merged visitor's CH rows (which would destroy
  # immutable canonical history), record an identity-map alias (merged -> survivor)
  # and mark the affected rollup partitions dirty. The next rollup rebuild resolves
  # the merged visitor's pre-merge canonical events through the map and folds them
  # under the survivor — counted once, never double-counted. Canonical stays immutable.
  #
  # Enqueues a SEPARATE retryable job rather than folding inline: the PG merge above
  # already committed and deleted from_visitor, so a whole-job retry would early-return
  # at the missing-from_visitor guard and never replay the fold. The dedicated job
  # owns the retry (record_merge raises on CH failure → Sidekiq retries → durable alias).
  #
  # NOTE: earliest install-source for the survivor is preserved transitively (the
  # merged visitor's install/first events now roll up under the survivor); the exact
  # argMin-based acquisition lands in Phase 5.
  def fold_visitor_into_survivor_in_clickhouse(project_id, merged_visitor_id, survivor_visitor_id)
    return unless merged_visitor_id && survivor_visitor_id

    MergeVisitorClickhouseFoldJob.perform_async(project_id, merged_visitor_id, survivor_visitor_id)
  rescue StandardError => e
    # The PG merge is already COMMITTED and from_visitor deleted. A failed ENQUEUE (e.g. a Redis
    # blip) must NOT escape into a whole-job retry — on retry from_visitor is gone, merge! early-
    # returns, and the fold is never re-enqueued (alias lost forever). So swallow the enqueue
    # failure and fold INLINE as a best-effort fallback (the job's body is idempotent). record_merge
    # talks to ClickHouse, so a Redis-only blip still records the alias here.
    Rails.logger.error(
      "MergeVisitorEventsJob: fold enqueue failed (#{e.class}: #{e.message}) — folding inline as fallback"
    )
    begin
      MergeVisitorClickhouseFoldJob.new.perform(project_id, merged_visitor_id, survivor_visitor_id)
    rescue StandardError => inner
      Rails.logger.error(
        "MergeVisitorEventsJob: inline fold fallback ALSO failed (#{inner.class}: #{inner.message}) — " \
        "alias #{merged_visitor_id}->#{survivor_visitor_id} in project #{project_id} NOT recorded"
      )
    end
  end

  # Best-effort TTL refresh after commit; the pre-delete write is the durable one.
  def refresh_merge_breadcrumb(project_id, from_device_id, to_device_id)
    write_merge_breadcrumb(project_id, from_device_id, to_device_id)
  rescue Redis::BaseError => e
    Rails.logger.warn("MergeVisitorEventsJob: breadcrumb refresh failed: #{e.message}")
  end

  # Mirrors after_commit :clear_cache; best-effort, self-heals via TTL.
  def invalidate_visitor_cache(cache_keys)
    REDIS.del(*cache_keys) if cache_keys.present?
  rescue Redis::BaseError => e
    Rails.logger.warn("MergeVisitorEventsJob: visitor cache invalidation failed: #{e.message}")
  end

  # Locks BOTH devices — target-only would let A→B and B→C run concurrently.
  # Non-blocking NX, so no deadlocks. Returns false on contention.
  def with_device_locks(from_device_id, to_device_id, project_id)
    token = SecureRandom.hex(16)
    keys = [from_device_id, to_device_id].sort.map { |id| "#{LOCK_PREFIX}:#{id}:#{project_id}" }

    held = []
    keys.each do |key|
      unless REDIS.set(key, token, nx: true, ex: LOCK_TTL)
        release_locks(held, token)
        Rails.logger.info("MergeVisitorEventsJob: #{key} contended, requeueing #{from_device_id}->#{to_device_id}")
        return false
      end
      held << key
    end

    begin
      yield
      true
    ensure
      release_locks(held, token)
    end
  end

  def renew_device_locks(from_device_id, to_device_id, project_id)
    [from_device_id, to_device_id].each do |id|
      REDIS.expire("#{LOCK_PREFIX}:#{id}:#{project_id}", LOCK_TTL)
    end
  end

  def release_locks(keys, token)
    keys.each do |key|
      REDIS.eval(SingleFlightJob::RELEASE_LUA, keys: [key], argv: [token])
    rescue Redis::BaseError => e
      # Lock self-expires via TTL — never fail the merge over a release
      Rails.logger.warn("MergeVisitorEventsJob: lock release failed for #{key}: #{e.message}")
    end
  end

  # Purchase ledger follows the survivor (batched: whale-visitor statement_timeout
  # safety; the block renews the merge locks per batch, like the event loop).
  # device_id repoints too (like events) so an UNPROCESSED purchase on the retired
  # device still resolves to the surviving visitor when it processes later.
  def repoint_purchase_ledger(project, from_visitor, to_visitor, from_device, to_device)
    PurchaseEvent.where(project_id: project.id, visitor_id: from_visitor.id)
                 .in_batches(of: 10_000) do |batch|
      batch.update_all(visitor_id: to_visitor.id)
      yield if block_given?
    end

    PurchaseEvent.where(device_id: from_device.id)
                 .in_batches(of: 10_000) do |batch|
      batch.update_all(device_id: to_device.id)
      yield if block_given?
    end
  end

  # Device-keyed state a renewal / first-purchase check reads by device, not visitor.
  def repoint_device_scoped_purchase_state(from_device, to_device)
    SubscriptionState.where(device_id: from_device.id).update_all(device_id: to_device.id)

    # Drop from-rows that would collide with an existing survivor row (unique device+project+product).
    DeviceProductPurchase.where(device_id: from_device.id).where(
      "EXISTS (SELECT 1 FROM device_product_purchases d2 WHERE d2.device_id = ? " \
      "AND d2.project_id = device_product_purchases.project_id " \
      "AND d2.product_id = device_product_purchases.product_id)", to_device.id
    ).delete_all
    DeviceProductPurchase.where(device_id: from_device.id).update_all(device_id: to_device.id)
  end

  # The CH fold (MergeVisitorClickhouseFoldJob) is separate and stays unconditional.
  def merge_visitor_stats(from_visitor, to_visitor)
    return unless Grovs.pg_shadow_writes?

    VisitorDailyStatistic.merge_visitors!(from_id: from_visitor.id, to_id: to_visitor.id)
  end

  # Rows that would self-attribute the target (from invited to) are nulled instead
  def repoint_referrals(from_visitor, to_visitor)
    if Grovs.pg_shadow_writes?
      VisitorDailyStatistic.where(invited_by_id: from_visitor.id)
                           .where.not(visitor_id: to_visitor.id)
                           .update_all(invited_by_id: to_visitor.id)
      VisitorDailyStatistic.where(invited_by_id: from_visitor.id, visitor_id: to_visitor.id)
                           .update_all(invited_by_id: nil)
    end
    Visitor.where(inviter_id: from_visitor.id)
           .where.not(id: to_visitor.id)
           .update_all(inviter_id: to_visitor.id)
    to_visitor.update_column(:inviter_id, nil) if to_visitor.inviter_id == from_visitor.id
  end

  # Cycles are impossible: resolve_target means we never merge into a
  # breadcrumbed device, so no device ever holds an outgoing breadcrumb
  # while being a merge target.
  BREADCRUMB_ATTEMPTS = 3

  # Retried: a failed write while the visitor is committed-deleted parks that
  # device's events until the Sidekiq retry rewrites it.
  def write_merge_breadcrumb(project_id, from_device_id, to_device_id)
    attempts = 0
    begin
      REDIS.set(BatchEventProcessorJob.merged_device_key(project_id, from_device_id), to_device_id, ex: 86_400)
    rescue Redis::BaseError
      raise if (attempts += 1) >= BREADCRUMB_ATTEMPTS

      sleep 0.05
      retry
    end
  end
end
