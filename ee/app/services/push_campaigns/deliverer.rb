module PushCampaigns
  class Deliverer
    SLICE = 1000
    NO_APP = "no_app".freeze
    NO_TOKEN = "no_token".freeze
    CAPPED = "capped".freeze
    NEVER_QUEUED = [NO_APP, NO_TOKEN, CAPPED].freeze
    CAP_TTL = 2.days.to_i
    # ~5s of rpush work across every project: keeps it busy while cancel and "sent" stay accurate.
    MAX_RPUSH_BACKLOG = 5000
    CLAIM_SQL = <<~SQL.freeze
      UPDATE push_deliveries SET status = 'claimed', updated_at = NOW()
      WHERE id IN (
        SELECT id FROM push_deliveries
        WHERE push_campaign_id = :campaign_id AND status = 'pending' AND due_at <= :now
        ORDER BY id LIMIT :limit FOR UPDATE SKIP LOCKED
      )
      RETURNING id, visitor_id, device_id, platform, variant, updated_at
    SQL

    def initialize(campaign)
      @campaign = campaign
      @payload = Payload.new(campaign)
      @daily_cap = InAppSetting.for(campaign.project).push_daily_cap
    end

    # :throttled while rpush is behind; the claimer only hands off as fast as rpush sends.
    def deliver_slice(now: Time.current)
      return :throttled if backlogged?

      rows = claim(now)
      return false if rows.empty?

      apps = PushCampaign::PUSH_PLATFORMS.index_with { |p| RpushService.app_for_platform(p, @campaign.project) }
      tokens = Device.where(id: rows.map { |r| r["device_id"] }).pluck(:id, :push_token).to_h
      built = Hash.new { |h, k| h[k] = [] }
      failed = Hash.new { |h, k| h[k] = [] }
      rows.each do |r|
        app = apps[r["platform"]]
        token = tokens[r["device_id"]]
        next failed[NO_APP] << r["id"] if app.nil?
        next failed[NO_TOKEN] << r["id"] if token.blank?

        built[notification_class_for(app)] << [r["id"], r]
      end
      sent = build(built, failed, apps, tokens, now)
      committed = false
      # rpush rows and the queued marks commit together, so a crash can never push a slice twice.
      ActiveRecord::Base.transaction do
        # Serialised with cancel!, which has already cancelled this claimed slice.
        return false unless PushCampaign::DELIVERING.include?(PushCampaign.lock.where(id: @campaign.id).pick(:status))

        sent = keep_held(rows, built, failed, sent, now)
        queued = built.sum { |klass, pairs| persist(klass, pairs) }
        failed.each { |error, ids| PushDelivery.where(id: ids).update_all(status: "failed", error: error, updated_at: Time.current) }
        PushCampaign.bump!(@campaign.id, queued: queued, failed: failed.values.sum(&:size), errors: failed.transform_values(&:size))
        committed = true
      end
      rows.size
    ensure
      unreserve(sent, now) if sent && !committed
    end

    def finish_if_done
      return false if @campaign.deliveries.where(status: %w[pending claimed]).exists?
      return false unless @campaign.transition!(from: %w[sending], to: "sent", finished_at: Time.current)

      Audit.record(instance_id: @campaign.project.instance_id, action: "push_campaign.sent", actor: AuditActor.system(self.class.name),
                   target: Audit.target_for(@campaign), changes: { "after" => @campaign.reload.report.slice(:targeted, :queued, :failed, :no_channel) })
      true
    end

    private

    # Uncached: Sidekiq's executor would cache this read for the whole 55s loop.
    def backlogged?
      Rpush::Client::ActiveRecord::Notification.uncached do
        Rpush::Client::ActiveRecord::Notification.where(delivered: false, failed: false)
                                                 .where("deliver_after IS NULL OR deliver_after < NOW()")
                                                 .limit(MAX_RPUSH_BACKLOG).count >= MAX_RPUSH_BACKLOG
      end
    end

    # Replaces each row with its notification, leaving out the capped; returns the rows whose allowance it reserved.
    def build(built, failed, apps, tokens, now)
      capped = reserve(built.values.flatten(1).map(&:last), now).to_set { |r| r["id"] }
      failed[CAPPED] = capped.to_a if capped.any?
      sent = []
      built.transform_values! do |pairs|
        pairs.filter_map do |id, r|
          next if capped.include?(id)

          sent << r
          [id, @payload.build(r["platform"], apps[r["platform"]], tokens[r["device_id"]], r["variant"])]
        end
      end
      sent
    end

    def cap_key(row, now) = "push:cap:#{@campaign.project_id}:#{row['visitor_id']}:#{now.utc.strftime('%Y%m%d')}"

    # INCR reserves one push per person and UTC day across campaigns; a reservation over the cap is given back at once.
    def reserve(rows, now)
      rows = rows.select { |r| r["visitor_id"] }
      return [] if @daily_cap.nil? || rows.empty?

      counts = REDIS.with { |conn| conn.pipelined { |pipe| rows.each { |r| pipe.incr(cap_key(r, now)) } } }
      over = rows.zip(counts).select { |_, n| n > @daily_cap }.map(&:first)
      REDIS.with { |conn| conn.pipelined { |pipe| rows.each { |r| pipe.expire(cap_key(r, now), CAP_TTL) } } }
      unreserve(over, now)
      over
    rescue Redis::BaseError => e
      Rails.logger.warn("push.daily_cap_unavailable #{e.class}")
      []
    end

    # Pushes that were not queued after all (cancelled or rolled back) give their reservation back.
    def unreserve(rows, now)
      rows = rows.select { |r| r["visitor_id"] }
      return if @daily_cap.nil? || rows.empty?

      REDIS.with { |conn| conn.pipelined { |pipe| rows.each { |r| pipe.decr(cap_key(r, now)) } } }
    rescue Redis::BaseError => e
      Rails.logger.warn("push.daily_cap_unavailable #{e.class}")
    end

    # A stale reset may have handed some rows to another claimer while this slice stalled.
    def keep_held(rows, built, failed, sent, now)
      held = PushDelivery.where(id: rows.map { |r| r["id"] }, status: "claimed", updated_at: rows.first["updated_at"])
                         .order(:id).lock.pluck(:id).to_set
      return sent if held.size == rows.size

      built.each_value { |pairs| pairs.select! { |id, _| held.include?(id) } }
      failed.each_value { |ids| ids.select! { |id| held.include?(id) } }.reject! { |_, ids| ids.empty? }
      lost, sent = sent.partition { |r| !held.include?(r["id"]) }
      unreserve(lost, now)
      sent
    end

    def notification_class_for(app)
      app.is_a?(Rpush::Apnsp8::App) ? Rpush::Apnsp8::Notification : Rpush::Fcm::Notification
    end

    def claim(now)
      sql = ActiveRecord::Base.sanitize_sql_array([CLAIM_SQL, { campaign_id: @campaign.id, now: now, limit: SLICE }])
      ActiveRecord::Base.connection.exec_query(sql).to_a
    end

    # One INSERT per rpush class; ids come back in insertion order (Postgres RETURNING).
    def persist(klass, pairs)
      result = klass.import(pairs.map(&:last), validate: false)
      updates = pairs.map(&:first).zip(result.ids).map do |delivery_id, rpush_id|
        { id: delivery_id, push_campaign_id: @campaign.id, status: "queued", rpush_notification_id: rpush_id }
      end
      PushDelivery.upsert_all(updates, update_only: %i[status rpush_notification_id])
      updates.size
    end
  end
end
