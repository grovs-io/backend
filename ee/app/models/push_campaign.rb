class PushCampaign < ApplicationRecord
  include Hashid::Rails

  STATUSES = %w[draft scheduled evaluating sending sent failed cancelled live paused].freeze
  # A journey step's campaign is live while the journey runs: rows keep arriving, so the deliverer never closes it.
  DELIVERING = %w[sending live].freeze
  AUDIENCE_TYPES = %w[segment visitors identifiers].freeze
  SOURCES = %w[dashboard api journey].freeze
  PUSH_PLATFORMS = [Grovs::Platforms::IOS, Grovs::Platforms::ANDROID].freeze
  MAX_RECIPIENTS = 10_000
  MAX_DATA_BYTES = 2048
  # Keys that would replace the APNs alert, trigger rpush's flags, or make FCM reject the message.
  RESERVED_DATA_KEYS = /\A(aps|from|notification|message_type|headers|__rpush_.*|google.*|gcm.*)\z/i
  MAX_SCHEDULE = 30.days
  EASTERNMOST_OFFSET = 14.hours
  MAX_LOCAL_TIME_LEAD = 26.hours # a UTC-12 campaign zone
  COUNTERS = %i[targeted no_channel not_found queued delivered failed opened cancelled].freeze
  VARIANT_IDS = %w[b c].freeze
  Invalid = Class.new(StandardError)
  RateLimited = Class.new(StandardError)
  IMAGE_TYPES = %w[image/png image/jpeg image/gif].freeze
  IMAGE_MAX_BYTES = 1.megabyte # Firebase loads at most 1 MB; iOS extensions time out on more

  belongs_to :project
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :link, optional: true
  belongs_to :segment, optional: true
  has_many :deliveries, class_name: "PushDelivery", dependent: :delete_all
  has_many :counter_shards, class_name: "PushCampaignCounter", dependent: :delete_all
  after_create { PushCampaignCounter.create_shards!(id) }
  has_one_attached :image

  validates :status, inclusion: { in: STATUSES }
  validates :audience_type, inclusion: { in: AUDIENCE_TYPES }
  validates :source, inclusion: { in: SOURCES }
  validates :name, :title, presence: true, length: { maximum: 255 }
  validates :body, presence: true, length: { maximum: 1000 }
  validates :image_url, length: { maximum: 2048 }, format: { with: %r{\Ahttps://\S+\z}, allow_blank: true }
  validates :sound, length: { maximum: 64 }
  validate :recipients_shape
  validate :data_size
  validate :link_in_project
  validate :segment_in_project
  validate :image_shape
  validate :schedule_shape
  validates :control_group, numericality: { only_integer: true, in: 1..50, message: "must be a whole number from 1 to 50" }, allow_nil: true
  validates :test_share, numericality: { only_integer: true, in: 10..50, message: "must be a whole number from 10 to 50" }, allow_nil: true
  validates :winner_after_minutes, inclusion: { in: Experiments::Winner::WAITS, message: "must be 30, 60, 120, 360, 720 or 1440" }, allow_nil: true
  validates :winner_by, inclusion: { in: Experiments::Winner::BY, message: "must be opens or conversions" }, allow_nil: true
  validate :experiment_shape
  validate :apns_payload_fits
  before_validation { self.timezone = "UTC" if timezone.blank? }

  scope :sending, -> { where(status: DELIVERING) }

  # The core gateway may name only this class (rake ee:boundary), so the service sits behind it.
  def self.server_create(project:, params:) = PushCampaigns::ApiCreate.call(project: project, params: params)

  def api_json = PushCampaignSerializer.serialize(self)

  # An explicit URL wins; else the saved upload, via the permanent asset URL links use.
  def image_resource
    return image_url if image_url.present?

    AssetService.permanent_url(image) if image.attached? && image.blob.persisted?
  end

  def editable? = status == "draft"
  def experiment? = control_group.present? || conversion.present? || variants.present?
  def variant_ids = ["a"] + Array(variants).map { |v| v["id"] }

  # Whether exposure is worth writing to ClickHouse: an experiment of its own, or a project-wide control group.
  def measured? = experiment? || InAppSetting.for(project).control_group.positive?

  def title_for(variant_id) = Array(variants).find { |v| v["id"] == variant_id }&.dig("title") || title
  def body_for(variant_id) = Array(variants).find { |v| v["id"] == variant_id }&.dig("body") || body

  # Claimed now and released by PushWinnerJob; a due timer also re-enqueues the job should it be lost.
  def choose_winner!(variant_id)
    with_lock do
      return false unless status == "sent" && waiting.positive? && winner.nil? && variant_ids.include?(variant_id)

      update_columns(winner: variant_id, winner_due_at: Time.current, updated_at: Time.current)
    end
    true
  end

  # The rows kept back for the winner go out as that variant; the campaign sends again from where it stopped.
  def send_winner!(variant_id)
    released = []
    with_lock do
      return false unless status == "sent" && waiting.positive? && variant_ids.include?(variant_id) && [nil, variant_id].include?(winner)

      released = deliveries.where(status: "waiting").pluck(:device_id)
      deliveries.where(status: "waiting").update_all(status: "pending", variant: variant_id, updated_at: Time.current)
      # No validation here: an archived segment must not stop people who were already frozen in from getting the winner.
      update_columns(status: "sending", waiting: 0, finished_at: nil, winner: variant_id, winner_due_at: nil, updated_at: Time.current)
    end
    expose(released, variant_id)
    true
  end

  # Full validation, then drop non-audience errors, so title/body can't block a draft-less estimate.
  def valid_audience?
    valid?
    (errors.attribute_names - %i[audience_type recipients segment]).each { |attr| errors.delete(attr) }
    errors.empty?
  end

  def zone = ActiveSupport::TimeZone[timezone.to_s]

  # A local-time send is due first at UTC+14, i.e. 14h minus the campaign zone's offset before scheduled_at.
  def local_time_lead = EASTERNMOST_OFFSET - scheduled_at.in_time_zone(zone || "UTC").utc_offset.seconds

  def release_at = local_time ? scheduled_at - local_time_lead : scheduled_at

  # Passed into the send transition so a re-send never overwrites what was approved.
  def segment_snapshot_attrs
    { segment_definition: segment.definition, segment_definition_hash: segment.definition_hash,
      segment_list_generation: segment.identifier_list_generation }
  end

  # Drops pending, claimed and waiting rows and unpicked rpush pushes; only rpush batches in flight finish.
  def cancel!
    with_lock do
      return false unless %w[draft scheduled sending].include?(status) || (status == "sent" && waiting.positive?)

      n = deliveries.where(status: %w[pending claimed waiting]).update_all(status: "cancelled", updated_at: Time.current)
      withdrawn = withdraw_unsent!
      update!(status: "cancelled", finished_at: Time.current, cancelled: cancelled + n + withdrawn, waiting: 0)
      PushCampaignCounter.bump!(id, queued: -withdrawn) if withdrawn.positive?
      counter_shards.reset
    end
    true
  end

  WITHDRAW_SQL = <<~SQL.freeze
    DELETE FROM rpush_notifications
    WHERE id IN (SELECT rpush_notification_id FROM push_deliveries WHERE push_campaign_id = :id AND status = 'queued')
      AND NOT delivered AND NOT failed AND NOT processing
    RETURNING id
  SQL

  # Pushes rpush has not picked up yet are withdrawn; the ones it is already sending still go out.
  def withdraw_unsent!
    sql = self.class.sanitize_sql_array([WITHDRAW_SQL, { id: id }])
    ids = self.class.with_connection { |c| c.exec_query(sql) }.rows.flatten
    return 0 if ids.empty?

    deliveries.where(status: "queued", rpush_notification_id: ids).update_all(status: "cancelled", updated_at: Time.current)
  end

  def transition!(from:, to:, **attrs)
    with_lock do
      return false unless from.include?(status)

      update!(attrs.merge(status: to))
    end
    true
  end

  # queued, delivered, failed and errors go to a shard: settles would otherwise queue on this row.
  def self.bump!(id, errors: {}, **counters)
    counters.each_key { |col| raise ArgumentError, "unknown counter #{col}" unless COUNTERS.include?(col.to_sym) }
    sharded, counters = counters.partition { |col, _| PushCampaignCounter::COUNTERS.include?(col.to_sym) }.map(&:to_h)
    # Row before shard, the order delivery, cancel! and recount! lock in.
    where(id: id).update_all("#{counters.map { |col, n| "#{col} = #{col} + #{Integer(n)}" }.join(', ')}, updated_at = NOW()") if counters.any?
    PushCampaignCounter.bump!(id, errors: errors, **sharded) if sharded.any? || errors.any?
  end

  # Row plus shards; pluck/where/SQL on these columns see only the row part.
  PushCampaignCounter::COUNTERS.each { |col| define_method(col) { super() + counter_shards.to_a.sum(&col) } }

  def error_counts
    counter_shards.to_a.map(&:error_counts).reduce(super().dup) { |acc, errs| acc.merge(errs) { |_, a, b| a + b } }
  end

  # Manual repair from the rows; locking the row and shards orders it against every bump.
  def recount!
    with_lock do
      shards = counter_shards.reset.lock.to_a
      rows = deliveries.group(:status, :error).count
      by_status = rows.each_with_object(Hash.new(0)) { |((status, _), n), acc| acc[status] += n }
      failed = rows.select { |(status, _), _| status == "failed" }
      never_queued = failed.sum { |(_, error), n| PushCampaigns::Deliverer::NEVER_QUEUED.include?(error) ? n : 0 }
      counts = { queued: by_status["queued"] + by_status["delivered"] + by_status["failed"] - never_queued, delivered: by_status["delivered"],
                 failed: by_status["failed"], cancelled: by_status["cancelled"], opened: deliveries.where.not(opened_at: nil).count,
                 error_counts: failed.each_with_object(Hash.new(0)) { |((_, error), n), acc| acc[error.to_s] += n } }
      changed = counts.reject { |k, v| public_send(k) == v }
      PushCampaignCounter.where(push_campaign_id: id, shard: shards.map(&:shard)).update_all(queued: 0, delivered: 0, failed: 0, error_counts: {})
      update_columns(counts.merge(updated_at: Time.current))
      counter_shards.reset
      changed.keys
    end
  end

  def report
    COUNTERS.index_with { |c| public_send(c) }.merge(held: held, waiting: waiting, error_counts: error_counts,
                                                     audience: { persons: audience_persons, devices: audience_devices, incomplete: audience_incomplete })
  end

  private

  # Intent to treat: the waiting share is exposed when handed the winner, whether or not the push arrives.
  def expose(device_ids, variant_id)
    return unless measured?

    device_ids.each_slice(10_000) do |slice|
      Experiments::Held.push(project_id, Experiments::Held::PUSH_DELIVERED, slice.map { |id| [id, { "campaign_id" => hashid, "variant" => variant_id }] })
    end
  rescue StandardError => e # the winner is already sent; a lost exposure only thins the report
    Grovs::Metrics.increment("push_campaign.expose_failed", tags: { error: e.class.name })
    Rails.logger.error("push_campaign.expose_failed #{id} #{e.class}: #{e.message}")
  end

  def experiment_shape
    problem = conversion.nil? ? nil : Experiments::Goal.problem(conversion)
    errors.add(:conversion, problem) if problem
    errors.add(:test_share, "needs variants to test") if test_share.present? && variants.blank?
    errors.add(:winner_after_minutes, "needs a test share") if winner_after_minutes.present? && test_share.blank?
    errors.add(:winner_by, "needs a goal to judge conversions by") if winner_by == "conversions" && conversion.blank?
    return if variants.nil?
    return errors.add(:variants, "must be a list of at most two") unless variants.is_a?(Array) && variants.size <= 2

    ids = variants.map { |v| v.is_a?(Hash) && v["id"] }
    texts = variants.all? { |v| v.is_a?(Hash) && (v.keys - %w[id title body]).empty? && text?(v["title"], 255) && text?(v["body"], 1000) }
    errors.add(:variants, "must be b, then c, each with a title (up to 255) and a body (up to 1000)") unless ids == VARIANT_IDS.first(ids.size) && texts
  end

  def text?(value, max) = value.is_a?(String) && value.strip.present? && value.length <= max

  def recipients_shape
    return errors.add(:recipients, "must be an array") unless recipients.is_a?(Array)
    return if source == "journey"

    return errors.add(:recipients, "at most #{MAX_RECIPIENTS}") if recipients.size > MAX_RECIPIENTS

    case audience_type
    when "visitors", "identifiers"
      errors.add(:recipients, "must be non-empty strings") unless recipients.any? && recipients.all? { |r| r.is_a?(String) && r.present? && r.bytesize <= 256 }
    when "segment"
      errors.add(:recipients, "must be empty for a segment audience") if recipients.any?
      errors.add(:segment, "is required") if segment.nil?
      errors.add(:segment, "is archived") if segment&.archived? && !%w[cancelled sent failed].include?(status)
    end
  end

  def data_size
    return errors.add(:data, "must be an object") unless data.is_a?(Hash)

    errors.add(:data, "must be under #{MAX_DATA_BYTES} bytes") if data.to_json.bytesize > MAX_DATA_BYTES
    reserved = data.keys.map(&:to_s).grep(RESERVED_DATA_KEYS)
    errors.add(:data, "can't use the reserved keys #{reserved.join(', ')}") if reserved.any? && will_save_change_to_data?
  end

  def schedule_shape
    errors.add(:timezone, "is not a known timezone") if zone.nil?
    errors.add(:local_time, "needs scheduled_at") if local_time && scheduled_at.nil?
    # The winner can only go out once every zone has had its test share; it would then land at the wrong local hour.
    errors.add(:test_share, "cannot be combined with local-time delivery") if local_time && test_share.present?
    return unless will_save_change_to_status?(to: "scheduled")

    errors.add(:scheduled_at, "must be in the future") if scheduled_at.nil? || scheduled_at <= Time.current
    errors.add(:scheduled_at, "must be within 30 days") if scheduled_at && scheduled_at > MAX_SCHEDULE.from_now
    return unless local_time && scheduled_at && release_at < Time.current

    errors.add(:scheduled_at, "must be at least #{(local_time_lead / 1.hour).ceil} hours away for local-time delivery in this timezone")
  end

  def link_in_project
    errors.add(:link, "must belong to this project") if link && link.domain&.project_id != project_id
  end

  def image_shape
    return unless image.attached? && attachment_changes.key?("image")

    errors.add(:image, "must be a PNG, JPEG or GIF") unless IMAGE_TYPES.include?(image.blob.content_type)
    errors.add(:image, "must be under #{IMAGE_MAX_BYTES / 1.megabyte} MB") if image.blob.byte_size > IMAGE_MAX_BYTES
  end

  # An unsaved upload has no URL to count (~120 bytes); only a body already at the cap slips past.
  def apns_payload_fits
    return if title.blank? || body.blank? || errors[:variants].any?

    limit = Rpush::Apnsp8::Notification.max_payload_bytesize
    variant_ids.each do |id|
      size = PushCampaigns::Payload.new(self).apns_bytesize(id)
      errors.add(:base, "push payload#{id == 'a' ? '' : " of variant #{id.upcase}"} is #{size} bytes; APNs allows #{limit}") if size > limit
    end
  end

  def segment_in_project
    errors.add(:segment, "must belong to this project") if segment && segment.project_id != project_id
  end
end
