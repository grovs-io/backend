# The server's only memory of views: a total per person and campaign, for the lifetime cap.
module InAppViews
  # Two full batches, so a batch sent again finds every one of its ids still here.
  RECENT = 100
  PERSON_VISITORS = 50
  UPSERT = <<~SQL.squish.freeze
    INSERT INTO in_app_views (in_app_campaign_id, person_key, project_id, total, recent, updated_at)
    VALUES (:campaign, :person, :project, 1, jsonb_build_array(:event), now())
    ON CONFLICT (in_app_campaign_id, person_key) DO UPDATE
    SET total = in_app_views.total + 1, updated_at = now(),
        recent = (SELECT jsonb_agg(e ORDER BY n)
                  FROM (SELECT e, n FROM jsonb_array_elements(in_app_views.recent || EXCLUDED.recent) WITH ORDINALITY AS t(e, n)
                        ORDER BY n DESC LIMIT #{RECENT}) kept)
    WHERE NOT in_app_views.recent @> EXCLUDED.recent
    RETURNING total
  SQL

  MERGE = <<~SQL.squish.freeze
    INSERT INTO in_app_views (in_app_campaign_id, person_key, project_id, total, recent, updated_at, answered_at)
    VALUES (:campaign, :person, :project, :total, CAST(:recent AS jsonb), now(), :answered)
    ON CONFLICT (in_app_campaign_id, person_key) DO UPDATE
    SET total = in_app_views.total + EXCLUDED.total, recent = in_app_views.recent || EXCLUDED.recent, updated_at = now(),
        answered_at = COALESCE(in_app_views.answered_at, EXCLUDED.answered_at)
  SQL

  ANSWER = <<~SQL.squish.freeze
    INSERT INTO in_app_views (in_app_campaign_id, person_key, project_id, total, recent, updated_at, answered_at)
    VALUES (:campaign, :person, :project, 0, '[]', now(), now())
    ON CONFLICT (in_app_campaign_id, person_key) DO UPDATE SET answered_at = now(), updated_at = now()
    WHERE in_app_views.answered_at IS NULL
    RETURNING total
  SQL

  RETENTION = 30.days
  PURGE_BATCH = 10_000
  PURGE_ROUNDS = 20

  module_function

  # Nothing reads the views of an ended campaign: sync never serves it and reports read ClickHouse.
  def purge_ended
    rounds = PURGE_ROUNDS
    ended = InAppCampaign.where(status: "ended", ended_at: ...RETENTION.ago).where(id: InAppView.select(:in_app_campaign_id))
    ended.pluck(:id).each do |id|
      while rounds.positive?
        rounds -= 1
        keys = InAppView.where(in_app_campaign_id: id).limit(PURGE_BATCH).pluck(:person_key)
        InAppView.where(in_app_campaign_id: id, person_key: keys).delete_all
        break if keys.size < PURGE_BATCH
      end
    end
  end

  def person_key(visitor) = visitor.sdk_identifier.present? ? "i:#{visitor.sdk_identifier}" : "v:#{visitor.id}"

  # A replayed event changes nothing, because its id is still among the recent ones.
  def record(campaign:, visitor:, event_id:)
    sql = InAppView.sanitize_sql([UPSERT, { campaign: campaign.id, person: person_key(visitor), project: campaign.project_id, event: event_id.to_s }])
    # execute, not a select: a select would leave the query cache holding the old total.
    total = InAppView.connection.execute(sql).first&.fetch("total")
    cap = campaign.caps["lifetime"]
    announce(visitor) if total && cap.is_a?(Integer) && total >= cap
    total
  end

  # True for the first answer only; the person's other devices are then told to sync, and lose the campaign.
  def answered(campaign:, visitor:)
    sql = InAppView.sanitize_sql([ANSWER, { campaign: campaign.id, person: person_key(visitor), project: campaign.project_id }])
    first = InAppView.connection.execute(sql).first.present?
    announce(visitor) if first
    first
  end

  def answered?(campaign:, visitor:)
    InAppView.where(in_app_campaign_id: campaign.id, person_key: person_key(visitor)).where.not(answered_at: nil).exists?
  end

  # What sync needs to know of a person, by campaign: how often they saw it and whether they answered it.
  def seen(project_id:, visitor:)
    InAppView.where(project_id: project_id, person_key: person_key(visitor)).pluck(:in_app_campaign_id, :total, :answered_at)
             .to_h { |id, total, answered| [id, { total: total, answered: answered.present? }] }
  end

  def totals(project_id:, visitor:) = seen(project_id: project_id, visitor: visitor).transform_values { |row| row[:total] }

  # Every device of the person must drop the campaign, not only the one that reported the view.
  def announce(visitor)
    ids = [visitor.id]
    if visitor.sdk_identifier.present?
      ids |= Visitor.where(project_id: visitor.project_id, sdk_identifier: visitor.sdk_identifier).limit(PERSON_VISITORS).pluck(:id)
    end
    InAppStamps.touch_users(ids)
  end

  # Into the key sync reads for the survivor, which is its identifier when it has one.
  def merge(from:, to:)
    carry(project_id: from.project_id, from: "v:#{from.id}", to: person_key(to))
    # A merge runs inside a transaction; a device told before it commits would sync and read the old rows.
    ActiveRecord.after_all_transactions_commit { announce(to) }
  end

  # A device that was anonymous now belongs to a person: its views join theirs, and it must sync again.
  def identified(visitor, changed:)
    moved = carry(project_id: visitor.project_id, from: "v:#{visitor.id}", to: person_key(visitor))
    announce(visitor) if moved || changed
  end

  # All or nothing, and true when there was something to move, so a transfer that failed is made again.
  def carry(project_id:, from:, to:)
    return false if from == to

    InAppView.transaction { move_rows(InAppView.where(project_id: project_id, person_key: from), to) }
  end

  def move_rows(scope, to)
    return false unless scope.exists?

    scope.order(:in_app_campaign_id).each do |row|
      values = { campaign: row.in_app_campaign_id, person: to, project: row.project_id, total: row.total, recent: row.recent.to_json,
                 answered: row.answered_at }
      InAppView.connection.execute(InAppView.sanitize_sql([MERGE, values]))
    end
    scope.delete_all
    true
  end
end
