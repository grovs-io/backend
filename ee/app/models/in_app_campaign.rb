class InAppCampaign < ApplicationRecord
  include Hashid::Rails

  STATUSES = %w[draft preparing scheduled live paused ended].freeze
  SERVED = %w[scheduled live].freeze
  ACTIVE = %w[preparing scheduled live paused].freeze
  AUDIENCE_TYPES = %w[all segment journey].freeze
  ACTIVE_LIMIT = 50
  SEGMENT_KEY_LIMIT = 20
  IMAGE_SLOTS = %w[portrait landscape].freeze
  IMAGE_TYPES = %w[image/png image/jpeg image/gif].freeze
  IMAGE_MAX_BYTES = 1.megabyte
  MEDIA_TYPES = { "image/png" => IMAGE_MAX_BYTES, "image/jpeg" => IMAGE_MAX_BYTES, "image/gif" => IMAGE_MAX_BYTES,
                  "video/mp4" => 20.megabytes, "audio/mpeg" => 10.megabytes, "audio/mp4" => 10.megabytes }.freeze
  MEDIA_COUNT_LIMIT = 30
  MEDIA_BYTES_LIMIT = 100.megabytes
  DEFINITION_FIELDS = %w[template content triggers conditions caps schedule priority delay_seconds start_at end_at variants].freeze
  EXPERIMENT_FIELDS = %w[control_group conversion variants].freeze
  VARIANT_IDS = %w[b c].freeze
  SYNCED_FIELDS = (DEFINITION_FIELDS + EXPERIMENT_FIELDS + %w[status segment_key]).uniq.freeze

  class Refused < StandardError; end

  belongs_to :project
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :segment, optional: true
  has_one_attached :portrait_image
  has_one_attached :landscape_image
  has_many_attached :media

  validates :name, presence: true, length: { maximum: 255 }
  validates :status, inclusion: { in: STATUSES }
  validates :audience_type, inclusion: { in: AUDIENCE_TYPES }
  validates :priority, numericality: { only_integer: true, in: 1..10, message: "must be a whole number from 1 to 10" }
  validates :delay_seconds, numericality: { only_integer: true, in: 0..3600, message: "must be a whole number of seconds, up to 3600" }
  validates :control_group, numericality: { only_integer: true, in: 1..50, message: "must be a whole number from 1 to 50" }, allow_nil: true
  validate :shapes
  validate :experiment_shape
  validate :small_enough
  validate :audience_shape
  # Pausing or ending must always work, so only a change to what devices receive is checked.
  validate :definition_holds, if: -> { !draft? && DEFINITION_FIELDS.intersect?(changed) }
  validate :template_kept, if: -> { launched_at_was.present? && template_changed? }
  validate :question_kept, if: -> { launched_at_was.present? && content_changed? }
  validate :split_kept, if: -> { launched_at_was.present? && (control_group_changed? || variants_changed?) }

  before_validation :keep_uploaded_images
  before_update :next_revision
  after_commit :announce

  scope :served, -> { where(status: SERVED) }
  scope :active, -> { where(status: ACTIVE) }

  def draft? = status == "draft"
  def definition = InAppDefinition.build(self)
  def experiment? = control_group.present? || conversion.present? || variants.present?
  def variant_ids = ["a"] + Array(variants).map { |v| v["id"] }

  # The definition a person in that variant receives; "a" is the campaign's own content.
  def definition_for(variant_id)
    variant = Array(variants).find { |v| v["id"] == variant_id }
    return definition if variant.nil?

    # Pictures are A's: uploads only ever write A, and a replaced file is purged.
    definition.merge("content" => InAppDefinition::CONTENT.merge(variant["content"]).merge("image" => image_addresses))
  end

  def variant_content(variant_id) = variant_id == "a" ? content : Array(variants).find { |v| v["id"] == variant_id }&.dig("content")

  # The campaign's own content and every variant's, as a device may hold any of them.
  def contents = [content.is_a?(Hash) ? content : {}] + Array(variants).filter_map { |v| v["content"] if v.is_a?(Hash) && v["content"].is_a?(Hash) }

  def transition!(from:, to:, **attrs)
    with_lock do
      return false unless from.include?(status)

      update!(attrs.merge(status: to))
    end
    true
  end

  # A segment campaign waits in preparing until its first membership is written.
  def launch!
    # The project is locked first, so two launches cannot both count 49 and make 51.
    project.with_lock do
      with_lock do
        return false unless draft?

        refuse_unless_launchable
        update!(launch_attrs)
      end
    end
    InAppMembershipPopulateJob.perform_async(id) if status == "preparing"
    true
  end

  # Every upload has its own address, so a device never shows a cached copy of the image it replaced.
  def attach_image(slot, file)
    # Read from the bytes, not from what the upload says it is.
    kind = Marcel::MimeType.for(file.respond_to?(:tempfile) ? file.tempfile : file)
    file.rewind if file.respond_to?(:rewind)
    return image_refused("must be a PNG, JPEG or GIF") unless IMAGE_TYPES.include?(kind) && IMAGE_TYPES.include?(file.content_type)
    return image_refused("must be under 1 MB") if file.size > IMAGE_MAX_BYTES

    transaction do
      public_send("#{slot}_image").attach(io: file, filename: file.original_filename, content_type: kind, metadata: { analyzed: true })
      address = AssetService.permanent_url(public_send("#{slot}_image"))
      update(content: content.merge("image" => image_addresses.merge(slot => address))) || raise(ActiveRecord::Rollback)
    end
  end

  # The file goes only once the save has held: a refused removal must leave a live campaign its picture.
  def remove_image(slot)
    blob = public_send("#{slot}_image").blob
    removed = transaction do
      public_send("#{slot}_image").detach
      update(content: content.merge("image" => image_addresses.merge(slot => nil)), variants: variants_without(slot)) || raise(ActiveRecord::Rollback)
    end
    return false unless removed

    blob&.purge_later
    true
  end

  # Caps are checked under the row lock so two concurrent uploads can't both clear one.
  def attach_media(file, expected_version: nil)
    kind = Marcel::MimeType.for(file.respond_to?(:tempfile) ? file.tempfile : file)
    file.rewind if file.respond_to?(:rewind)
    limit = MEDIA_TYPES[kind]
    return media_refused("must be a PNG, JPEG, GIF, MP4, MP3 or M4A") unless limit
    return media_refused("must be under #{limit / 1.megabyte} MB") if file.size > limit

    # Pre-analyzed: the analyze job's blob update touches the campaign and bumps the lock_version we return.
    blob = ActiveStorage::Blob.create_and_upload!(io: file, filename: file.original_filename, content_type: kind, identify: false,
                                                  metadata: { analyzed: true })
    attached = false
    begin
      with_lock do
        raise ActiveRecord::StaleObjectError.new(self, "attach_media") if expected_version && expected_version != lock_version

        if media.attachments.count >= MEDIA_COUNT_LIMIT
          media_refused("a campaign can hold at most #{MEDIA_COUNT_LIMIT} files")
        elsif media.blobs.sum(:byte_size) + blob.byte_size > MEDIA_BYTES_LIMIT
          media_refused("a campaign can hold at most 100 MB of media")
        else
          attached = !media.attach(blob).nil?
          reload if attached # the version the caller answers with must be read under this lock
        end
      end
    ensure
      blob.purge unless attached
    end
    attached ? blob : nil
  end

  # A file is "in use" once its address is written into the html a device would actually receive.
  def media_in_use?(blob) = contents.any? { |c| AssetService.names?(c["html"], blob) }

  # Only files the copy's own html (after a variant-only duplicate narrows it) actually references travel with it.
  def copy_media_from(source)
    moved = source.media.attachments.filter_map do |attachment|
      next unless AssetService.names?([content, variants], attachment.blob)

      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(attachment.blob.download), filename: attachment.blob.filename.to_s,
                                                    content_type: attachment.blob.content_type, metadata: { analyzed: true })
      copied_blobs << blob
      media.attach(blob)
      [attachment.blob, blob]
    rescue ActiveStorage::FileNotFoundError
      nil
    end
    return true if moved.empty?

    fields = moved.reduce([content, variants]) { |value, (from, to)| AssetService.swap(value, from, to) }
    update(content: fields[0], variants: fields[1])
  end

  # A copy owns its own files; an address the source only named, and never uploaded, is kept as it is.
  def copy_images_from(source)
    copied = IMAGE_SLOTS.select do |slot|
      image = source.public_send("#{slot}_image")
      next false unless image.attached?

      public_send("#{slot}_image").attach(io: StringIO.new(image.download), filename: image.filename.to_s, content_type: image.content_type,
                                          metadata: { analyzed: true })
    rescue ActiveStorage::FileNotFoundError
      self.content = content.merge("image" => image_addresses.merge(slot => nil))
      false
    end
    # Named here: keep_uploaded_images skips an attachment still in this save, which left the slot empty.
    own = copied.index_with { |slot| AssetService.permanent_url(public_send("#{slot}_image")) }
    update(content: content.merge("image" => image_addresses.merge(own)))
  end

  # A rolled-back copy loses its blob rows but not the uploaded files, so those are deleted here.
  def discard_copies
    copied_blobs.each { |blob| blob.service.delete(blob.key) }
    copied_blobs.clear
  end

  # The segment as it is now, frozen; nil when there is no segment to freeze.
  def audience_snapshot
    return nil if audience_type != "segment" || segment.nil?

    key = InAppMemberships.key_for(project_id, segment.definition_hash, segment.identifier_list_generation)
    keys = InAppMemberships.tracked_keys(project_id, except_campaign: id)
    raise Refused, "A project can target #{SEGMENT_KEY_LIMIT} segments at once" if keys.exclude?(key) && keys.size >= SEGMENT_KEY_LIMIT

    { segment_definition: segment.definition, segment_definition_hash: segment.definition_hash,
      segment_list_generation: segment.identifier_list_generation, segment_key: key }
  end

  def go_live_attrs = { status: start_at&.future? ? "scheduled" : "live" }

  # A system flip, so lock_version stays put: a composer opened while preparing must still save.
  def go_live!
    done = with_lock do
      next false unless status == "preparing"

      update_columns(status: go_live_attrs[:status], updated_at: Time.current)
    end
    InAppStamps.touch_campaigns(project_id) if done
    done
  end

  def end!
    done = transition!(from: %w[preparing scheduled live paused], to: "ended", ended_at: Time.current)
    InAppMembershipCleanupJob.perform_async([segment_key]) if done && segment_key
    done
  end

  private

  def copied_blobs = @copied_blobs ||= []

  # An upload is the server's to name: a save that leaves the image out, or names another, cannot lose it.
  def keep_uploaded_images
    # An alert shows no picture: its uploads stay on file, unnamed, and return if the template changes back.
    return unless content.is_a?(Hash) && template != "alert"

    held = IMAGE_SLOTS.select { |slot| public_send("#{slot}_image").attached? && !attachment_changes.key?("#{slot}_image") }
    return if held.empty?

    addresses = held.index_with { |slot| AssetService.permanent_url(public_send("#{slot}_image")) }
    self.content = content.merge("image" => image_addresses.merge(addresses))
  end

  def image_addresses = { "portrait" => nil, "landscape" => nil }.merge(content["image"].is_a?(Hash) ? content["image"] : {})

  # Variants show A's pictures, so a removed one leaves theirs too.
  def variants_without(slot)
    return variants unless variants.is_a?(Array)

    variants.map do |v|
      next v unless v.is_a?(Hash) && v["content"].is_a?(Hash) && v["content"]["image"].is_a?(Hash)

      v.merge("content" => v["content"].merge("image" => v["content"]["image"].merge(slot => nil)))
    end
  end

  def image_refused(reason)
    errors.add(:image, reason)
    false
  end

  def media_refused(reason)
    errors.add(:media, reason)
    nil
  end

  # Checked as it will be once launched: a campaign with no start of its own starts now.
  def refuse_unless_launchable
    raise Refused, "Choose a segment for the audience" if audience_type == "segment" && segment.nil?
    raise Refused, "The segment is archived" if segment&.archived?

    self.launched_at = Time.current
    problems = all_problems
    restore_attributes(["launched_at"]) if problems.any?
    raise Refused, problems.first(3).join("; ") if problems.any?
    running = project.in_app_campaigns.active.where.not(audience_type: "journey").count
    raise Refused, "A project can run #{ACTIVE_LIMIT} campaigns at once" if running >= ACTIVE_LIMIT
  end

  def launch_attrs
    attrs = { launched_at: Time.current, failure_reason: nil }
    return attrs.merge(go_live_attrs) unless audience_type == "segment"

    attrs.merge(audience_snapshot, status: "preparing")
  end

  def shapes
    errors.add(:content, "must be an object") unless content.is_a?(Hash)
    errors.add(:caps, "must be an object") unless caps.is_a?(Hash)
    errors.add(:schedule, "must be an object") unless schedule.is_a?(Hash)
    errors.add(:triggers, "must be a list") unless triggers.is_a?(Array)
    errors.add(:conditions, "must be a list") unless conditions.is_a?(Array)
  end

  # A draft is checked for little else, so without this one could hold megabytes.
  def small_enough
    return if errors.any?

    size = InAppDefinition.size_of({ "content" => content, "triggers" => triggers, "conditions" => conditions, "caps" => caps, "schedule" => schedule })
    errors.add(:base, "The campaign is larger than 16 KB") if size > InAppDefinition::MAX_BYTES
    # size_of excludes html, so a draft (which skips the schema and definition_holds) needs its own check here.
    errors.add(:base, "The HTML is larger than 64 KB") if html_too_big?(content)
    Array(variants).each do |v|
      errors.add(:variants, "each must be under 16 KB") if InAppDefinition.size_of({ "content" => v["content"] }) > InAppDefinition::MAX_BYTES
      errors.add(:variants, "each HTML must be under 64 KB") if html_too_big?(v["content"])
    end
  end

  def html_too_big?(content) = content.is_a?(Hash) && content["html"].to_s.bytesize > InAppDefinition::HTML_MAX_BYTES

  def experiment_shape
    problem = conversion.nil? ? nil : Experiments::Goal.problem(conversion)
    errors.add(:conversion, problem) if problem
    return if variants.nil?
    return errors.add(:variants, "must be a list of at most two") unless variants.is_a?(Array) && variants.size <= 2

    ids = variants.map { |v| v.is_a?(Hash) && v["id"] }
    shaped = ids == VARIANT_IDS.first(ids.size) && variants.all? { |v| v["content"].is_a?(Hash) && (v.keys - %w[id content]).empty? }
    return errors.add(:variants, "must be b, then c, each with content") unless shaped

    errors.add(:variants, "must ask the same question as the message: same id, kind and options") unless variants.all? { |v| same_question?(v["content"]) }
  end

  def audience_shape
    return errors.add(:audience_type, "journey belongs to journey steps only") if audience_type == "journey" && !segment_key.to_s.start_with?("j:")
    return errors.add(:segment, "must be empty unless the audience is a segment") if audience_type != "segment" && segment_id
    return unless audience_type == "segment" && draft?

    errors.add(:segment, "is required") if segment.nil?
    errors.add(:segment, "must belong to this project") if segment && segment.project_id != project_id
  end

  def definition_holds
    return if errors.any?

    all_problems.first(3).each { |problem| errors.add(:base, problem) }
  end

  # Every variant is checked as its own definition, since each is what some devices receive.
  def all_problems
    variant_ids.flat_map do |id|
      InAppDefinition.problems(definition_for(id)).map { |problem| id == "a" ? problem : "Variant #{id.upcase}: #{problem}" }
    end
  end

  def template_kept = errors.add(:template, "cannot change after launch")

  # The answers already given are read by the question's kind; a new kind would make them meaningless.
  def question_kept
    was = content_was.is_a?(Hash) ? content_was["question"] : nil
    now = content.is_a?(Hash) ? content["question"] : nil
    return if was.nil? && now.nil?

    errors.add(:base, "The question cannot be added, removed or changed to another kind after launch") if was.nil? != now.nil? || was["type"] != now["type"]
  end

  # Answers are reported by A's question, so a variant may reword it but not ask another.
  def same_question?(other)
    mine = content.is_a?(Hash) ? content["question"] : nil
    theirs = other["question"]
    return mine.nil? if theirs.nil?
    return false unless mine.is_a?(Hash) && theirs.is_a?(Hash)

    ids = ->(q) { Array(q["options"]).map { |o| o.is_a?(Hash) ? o["id"] : o } }
    %w[id type].all? { |k| mine[k] == theirs[k] } && ids.call(mine) == ids.call(theirs)
  end

  # Moving the split after launch would move people between groups and make the numbers meaningless.
  def split_kept
    was = variants_was.is_a?(Array) ? variants_was.map { |v| v["id"] } : []
    now = variants.is_a?(Array) ? variants.map { |v| v["id"] } : []
    errors.add(:base, "The control group and the variants cannot change after launch") if control_group_changed? || was != now
  end

  def next_revision
    self.revision += 1 if launched_at_was.present? && DEFINITION_FIELDS.intersect?(changed)
  end

  # Drafts are invisible to devices, and a media attach or purge only touches the row: neither sends devices to sync.
  def announce
    return if draft? && !saved_change_to_status?
    return unless destroyed? || SYNCED_FIELDS.intersect?(saved_changes.keys)

    InAppStamps.touch_campaigns(project_id)
  end
end
