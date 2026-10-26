class Journey < ApplicationRecord
  include Hashid::Rails

  STATUSES = %w[draft live paused ended].freeze
  RUNNING = %w[live paused].freeze
  STEP_TYPES = %w[wait split push in_app set_attribute].freeze
  STEP_ID = /\A[a-z0-9_]{1,16}\z/
  MAX_STEPS = 60
  LIVE_LIMIT = 20
  PERSON_DAYS = 90
  RE_ENTRY = %w[once after_exit after_days].freeze
  FIELDS = {
    "wait" => %w[minutes until next timeout_next], "split" => %w[mode condition yes_next no_next paths],
    "push" => %w[title body link_id image_url data sound quiet_hours campaign_id next],
    "in_app" => %w[template content triggers caps valid_days campaign_id next], "set_attribute" => %w[key value next]
  }.freeze
  # What may change once people are moving through the map: content and timing, never where a path leads.
  EDITABLE = { "wait" => %w[minutes], "split" => %w[paths], "push" => %w[title body link_id image_url data sound quiet_hours],
               "in_app" => %w[content triggers caps valid_days], "set_attribute" => %w[value] }.freeze
  FILTER_OPS = %w[is_set is_not_set between eq neq gt lt contains not_contains].freeze
  FIELD = /\A[A-Za-z0-9_]{1,64}\z/
  ATTRIBUTE_OPS = %w[eq neq contains exists not_exists gt lt].freeze
  ATTRIBUTE_KEY = /\Ajourney_[a-z0-9_]{1,40}\z/
  PLATFORMS = [Grovs::Platforms::IOS, Grovs::Platforms::ANDROID, Grovs::Platforms::WEB].freeze
  LOCKED = "The steps, entry and goals cannot change after launch".freeze

  class Refused < StandardError; end

  belongs_to :project
  belongs_to :created_by, class_name: "User", optional: true
  has_many :people, class_name: "JourneyPerson", dependent: :delete_all
  has_many_attached :images

  validates :name, presence: true, length: { maximum: 255 }
  validates :status, inclusion: { in: STATUSES }
  validates :control_group, numericality: { only_integer: true, in: 1..50, message: "must be a whole number from 1 to 50" }, allow_nil: true
  validate :entry_shape
  validate :re_entry_shape
  validate :goals_shape
  validate :steps_shape
  validate :schedule_shape
  validate :kept_after_launch, if: -> { launched_at_was.present? }

  before_validation :keep_campaign_ids
  before_update { self.revision += 1 if launched_at_was.present? && steps_changed? }
  after_save :sync_channels, if: -> { launched_at.present? && saved_change_to_steps? }
  after_commit { Journeys::Watchlist.refresh(project_id) }

  scope :running, -> { where(status: RUNNING) }

  def draft? = status == "draft"
  # A draft saves with parts not yet chosen; launch checks them through strict_problems.
  def lenient? = draft? && !@strict
  def step(id) = steps[id.to_s]
  def goal = goals.first
  def entry_open?(now = Time.current) = status == "live" && (start_at.nil? || start_at <= now) && (end_at.nil? || end_at > now)

  # The experiments report reads a journey as a campaign with one variant; its first goal sets the window.
  def conversion = goal
  def variant_ids = ["a"]
  def experiment? = goals.any? || control_group.to_i.positive?

  # The branches a step leads to, by the pointer's name; nil ends the path.
  def self.pointers(step)
    return {} unless step.is_a?(Hash)

    case step["type"]
    when "wait" then step["until"] ? step.slice("next", "timeout_next") : step.slice("next")
    when "split"
      return step.slice("yes_next", "no_next") unless step["mode"] == "percent"

      Array(step["paths"]).each_with_index.to_h { |path, i| ["path_#{i}", path.is_a?(Hash) ? path["next"] : nil] }
    else step.slice("next")
    end
  end

  delegate :pointers, to: :class

  # Everything that must hold before launch, beyond what a draft may save with.
  def problems
    found = []
    found << "Choose how people enter" if entry["type"].blank?
    return found + ["Add a first step"] if steps.empty? || first_step.blank?

    unreachable = steps.keys - reachable
    found << "Step #{unreachable.first} cannot be reached from the first step" if unreachable.any?
    found << "The end has already passed" if end_at&.past?
    found << "A segment this journey uses is archived" if segments_used.any?(&:archived?)
    steps.each_value { |step| found.concat(step_problems(step).map { |p| "Step #{step['id']}: #{p}" }) }
    (found + strict_problems).uniq
  end

  def strict_problems
    @strict = true
    valid? ? [] : errors.full_messages
  ensure
    @strict = false
  end

  def launch!(by: nil)
    project.with_lock do
      with_lock do
        return false unless draft?

        found = problems
        raise Refused, found.first(3).join("; ") if found.any?
        raise Refused, "A project can run #{LIVE_LIMIT} journeys at once" if project.journeys.running.count >= LIVE_LIMIT

        keys = tracked_keys
        taken = InAppMemberships.tracked_keys(project_id)
        raise Refused, "A project can target #{InAppCampaign::SEGMENT_KEY_LIMIT} segments at once" if (taken | keys.values.pluck("key")).size > InAppCampaign::SEGMENT_KEY_LIMIT

        now = Time.current
        @launching = true
        self.steps = steps.transform_values { |s| (campaign = create_channel(s, by, now)) ? s.merge("campaign_id" => campaign.hashid) : s }
        update!(status: "live", launched_at: now, segment_keys: keys)
      ensure
        @launching = false
      end
    end
    InAppMembershipRefreshJob.perform_async(nil, id) if segment_keys.any?
    open_entry!
    true
  end

  def pause! = move_to(from: %w[live], to: "paused")
  def resume! = move_to(from: %w[paused], to: "live")

  # Nobody new enters; people inside finish, so the channels stay up until the tick finds nobody left.
  def end!
    with_lock do
      return false unless RUNNING.include?(status)

      paused = status == "paused"
      update!(status: "ended", ended_at: Time.current)
      channels_to("live") if paused
    end
    true
  end

  # Once entry opens (launch, start_at, resume) the sweep runs; it stamps entry_opened_at, so the tick retries until then.
  def open_entry!
    return false unless entry_open?

    JourneySweepJob.perform_async(id)
    true
  end

  # Called by the tick once an ended journey has nobody left in it; queued pushes must go out first.
  def finish!
    return false if PushDelivery.where(push_campaign_id: channel_ids("push"), status: %w[pending claimed]).exists?

    InAppCampaign.where(id: channel_ids("in_app")).find_each(&:end!)
    PushCampaign.where(id: channel_ids("push"), status: "live").update_all(status: "sent", finished_at: Time.current, updated_at: Time.current)
    update_columns(finished_at: Time.current, updated_at: Time.current)
    InAppMembershipCleanupJob.perform_async(segment_keys.values.pluck("key")) if segment_keys.any?
    Journeys::Watchlist.refresh(project_id)
    true
  end

  # Journeys have no media delete, so files no step names are dropped once a day old, before the caps count.
  def attach_image(file, expected_version: nil)
    kind = Marcel::MimeType.for(file.respond_to?(:tempfile) ? file.tempfile : file)
    file.rewind if file.respond_to?(:rewind)
    limit = InAppCampaign::MEDIA_TYPES[kind]
    return image_refused("must be a PNG, JPEG, GIF, MP4, MP3 or M4A") unless limit
    return image_refused("must be under #{limit / 1.megabyte} MB") if file.size > limit

    # Pre-analyzed: the analyze job's blob update touches the journey and bumps the lock_version we return.
    blob = ActiveStorage::Blob.create_and_upload!(io: file, filename: file.original_filename, content_type: kind, identify: false,
                                                  metadata: { analyzed: true })
    attached = false
    begin
      with_lock do
        raise ActiveRecord::StaleObjectError.new(self, "attach_image") if expected_version && expected_version != lock_version

        stale, kept = images.attachments.includes(:blob).partition { |a| a.blob.created_at < 1.day.ago && !AssetService.names?(steps, a.blob) }
        stale.each(&:purge_later)
        if kept.size >= InAppCampaign::MEDIA_COUNT_LIMIT
          image_refused("a journey can hold at most #{InAppCampaign::MEDIA_COUNT_LIMIT} files")
        elsif kept.sum { |a| a.blob.byte_size } + blob.byte_size > InAppCampaign::MEDIA_BYTES_LIMIT
          image_refused("a journey can hold at most 100 MB of media")
        else
          attached = !images.attach(blob).nil?
          reload if attached # the version the caller answers with must be read under this lock
        end
      end
    ensure
      blob.purge unless attached
    end
    AssetService.absolute_url(blob) if attached
  end

  def duplicate(by:)
    copy = project.journeys.new(slice("entry", "re_entry", "goals", "control_group", "start_at", "end_at", "first_step"))
    copy.assign_attributes(name: "#{name} copy".first(255), created_by: by, steps: steps.transform_values { |s| s.except("campaign_id") })
    copy
  end

  # The copy owns its own files, and its steps name their new addresses, so deleting the source leaves it whole.
  def copy_images_from(source)
    moved = source.images.attachments.filter_map do |image|
      next unless AssetService.names?(source.steps, image.blob)

      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(image.download), filename: image.filename.to_s, content_type: image.content_type,
                                                    metadata: { analyzed: true })
      copied_blobs << blob
      images.attach(blob)
      [image.blob, blob]
    rescue ActiveStorage::FileNotFoundError
      nil
    end
    return true if moved.empty?

    update(steps: moved.reduce(steps) { |value, (from, to)| AssetService.swap(value, from, to) })
  end

  # A rolled-back copy loses its blob rows but not the uploaded files, so those are deleted here.
  def discard_copies
    copied_blobs.each { |blob| blob.service.delete(blob.key) }
    copied_blobs.clear
  end

  def channel_ids(type)
    klass = type == "push" ? PushCampaign : InAppCampaign
    ids = steps.values.select { |s| s["type"] == type }.filter_map { |s| s["campaign_id"] }
    ids.filter_map { |hashid| klass.decode_id(hashid) }
  end

  # Segment key per segment hashid, plus the entry's own key: newcomers are read off it, so no campaign may share it.
  def tracked_keys
    segments_used.each_with_object({}) do |segment, out|
      spec = { "segment_id" => segment.id, "definition" => segment.definition, "definition_hash" => segment.definition_hash,
               "list_generation" => segment.identifier_list_generation }
      if filter_hashids.include?(segment.hashid)
        out[segment.hashid] = spec.merge("key" => InAppMemberships.key_for(project_id, segment.definition_hash, segment.identifier_list_generation))
      end
      next unless entry["type"] == "segment" && entry["segment_id"] == segment.hashid

      salted = "journey:#{hashid}:#{segment.definition_hash}"
      out["entry"] = spec.merge("key" => InAppMemberships.key_for(project_id, salted, segment.identifier_list_generation))
    end
  end

  def membership_key(step_id) = "j:#{hashid}:#{step_id}"

  def reachable = reachable_from([first_step])

  # Steps reachable from these ids, the ids included; one search for launch checks and for "above".
  def reachable_from(ids)
    seen = []
    queue = ids.dup
    until queue.empty?
      id = queue.shift
      next if id.nil? || seen.include?(id) || !steps.key?(id)

      seen << id
      queue.concat(pointers(steps[id]).values)
    end
    seen
  end

  private

  def copied_blobs = @copied_blobs ||= []

  def image_refused(reason)
    errors.add(:image, reason)
    nil
  end

  def move_to(from:, to:)
    with_lock do
      return false unless from.include?(status)

      update!({ status: to }.merge(to == "live" ? { entry_opened_at: nil } : {}))
      channels_to(to)
    end
    open_entry! if to == "live"
    true
  end

  # Paused push campaigns keep their queued rows back; the deliverer and its tick read only sending and live ones.
  def channels_to(state)
    InAppCampaign.where(id: channel_ids("in_app")).find_each { |c| c.transition!(from: %w[live paused], to: state) }
    PushCampaign.where(id: channel_ids("push"), status: %w[live paused]).update_all(status: state, updated_at: Time.current)
  end

  def filter_hashids
    ids = steps.values.filter_map { |s| s.dig("condition", "segment_id") if s.is_a?(Hash) && s["type"] == "split" && s["condition"].is_a?(Hash) }
    ([entry["audience_segment_id"]] + ids).compact.uniq
  end

  def segment_hashids = ([entry["segment_id"]] + filter_hashids).compact.uniq

  def segments_used = @segments_used ||= project.segments.where(id: segment_hashids.filter_map { |h| Segment.decode_id(h) }).to_a

  def create_channel(step, by, now)
    case step["type"]
    when "push"
      campaign = PushCampaign.new(push_attrs(step).merge(project: project, created_by: by, name: channel_name(step), source: "journey",
                                                         status: "live", audience_type: "visitors", started_at: now))
      campaign.save!
      campaign
    when "in_app"
      InAppCampaign.create!(in_app_attrs(step).merge(project: project, created_by: by, name: channel_name(step), audience_type: "journey",
                                                     segment_key: membership_key(step["id"]), status: "live", launched_at: now))
    end
  end

  def channel_name(step) = "#{name.first(200)} · #{step['id']}"

  def push_attrs(step)
    { title: step["title"].to_s, body: step["body"].to_s, link_id: step["link_id"], image_url: step["image_url"].presence,
      data: step["data"] || {}, sound: step["sound"].presence }
  end

  def in_app_attrs(step)
    { template: step["template"], content: step["content"] || {}, triggers: step["triggers"] || [], caps: step["caps"] || {} }
  end

  # A launched step's campaign follows the edits; a refused edit rolls the journey back with it.
  def sync_channels
    was = saved_change_to_steps&.first || {}
    steps.each_value do |step|
      next if step["campaign_id"].blank?
      next if was[step["id"]].is_a?(Hash) && EDITABLE[step["type"]].all? { |field| was[step["id"]][field] == step[field] }

      if step["type"] == "push"
        PushCampaign.find_by_hashid(step["campaign_id"])&.update!(push_attrs(step))
      elsif step["type"] == "in_app"
        InAppCampaign.find_by_hashid(step["campaign_id"])&.update!(in_app_attrs(step))
      end
    end
  end

  # The campaign ids are the server's: whatever a save sends, a step keeps the one it had.
  def keep_campaign_ids
    return if @launching || !steps.is_a?(Hash)

    was = steps_was.is_a?(Hash) ? steps_was : {}
    self.steps = steps.to_h do |id, s|
      next [id, s] unless s.is_a?(Hash)

      [id, s.except("campaign_id").merge(was.dig(id, "campaign_id") ? { "campaign_id" => was.dig(id, "campaign_id") } : {})]
    end
  end

  def step_problems(step)
    case step["type"]
    when "push"
      campaign = PushCampaign.new(push_attrs(step).merge(project: project, name: "check", source: "journey", status: "draft", audience_type: "visitors"))
      campaign.valid? ? [] : campaign.errors.full_messages
    when "in_app"
      InAppDefinition.problems(InAppCampaign.new(in_app_attrs(step).merge(project: project, name: "check")).definition)
    else []
    end
  end

  def entry_shape
    return errors.add(:entry, "must be an object") unless entry.is_a?(Hash)
    return errors.add(:entry, "holds unknown fields") unless (entry.keys - %w[type event segment_id audience_segment_id]).empty?
    return if entry.empty? && draft?

    case entry["type"]
    when "event"
      problem = event_problem(entry["event"])
      errors.add(:entry, "event #{problem}") if problem
      errors.add(:entry, "segment_id must be null for an event entry") if entry["segment_id"]
    when "segment"
      errors.add(:entry, "needs a segment") if entry["segment_id"].blank? && !lenient?
      errors.add(:entry, "event must be null for a segment entry") if entry["event"]
    else errors.add(:entry, "type must be event or segment")
    end
    [entry["segment_id"], entry["audience_segment_id"]].compact.each { |id| errors.add(:entry, "names a segment that was not found") unless segment?(id) }
  end

  def re_entry_shape
    mode = re_entry.is_a?(Hash) ? re_entry["mode"] : nil
    return errors.add(:re_entry, "mode must be once, after_exit or after_days") unless RE_ENTRY.include?(mode)

    days = re_entry["days"]
    return if mode == "after_days" ? days.is_a?(Integer) && days.between?(1, 365) : days.nil?
    return if mode == "after_days" && lenient? && (days.nil? || days == 0)

    errors.add(:re_entry, mode == "after_days" ? "days must be a whole number from 1 to 365" : "days must be null unless the mode is after_days")
  end

  def goals_shape
    return errors.add(:goals, "must be a list of at most three") unless goals.is_a?(Array) && goals.size <= 3

    goals.each do |g|
      next if lenient? && g.is_a?(Hash) && (g.keys - Experiments::Goal::KEYS).empty? && Experiments::Goal::NAMES.all? { |k| g[k].blank? }

      (problem = Experiments::Goal.problem(g)) && errors.add(:goals, problem)
    end
  end

  def schedule_shape
    errors.add(:end_at, "must be after the start") if start_at && end_at && end_at <= start_at
  end

  def steps_shape
    return errors.add(:steps, "must be an object") unless steps.is_a?(Hash)
    return errors.add(:steps, "can be at most #{MAX_STEPS}") if steps.size > MAX_STEPS
    return errors.add(:first_step, "must be null without steps") if steps.empty? && first_step.present?
    return if steps.empty?

    errors.add(:first_step, "must be one of the steps") unless steps.key?(first_step)
    steps.each do |id, step|
      problem = step_shape(id, step)
      errors.add(:steps, "#{id}: #{problem}") if problem
    end
    errors.add(:steps, "cannot loop back to an earlier step") if errors[:steps].empty? && cycle?
  end

  def step_shape(id, step)
    return "must be an object with the same id" unless id.to_s.match?(STEP_ID) && step.is_a?(Hash) && step["id"] == id
    return "type must be one of #{STEP_TYPES.join(', ')}" unless STEP_TYPES.include?(step["type"])
    return "holds unknown fields" unless (step.keys - %w[id type] - FIELDS[step["type"]]).empty?

    missing = pointers(step).values.compact.reject { |target| steps.key?(target) }
    return "leads to #{missing.first}, which is not a step" if missing.any?

    send("#{step['type']}_problem", step)
  end

  def wait_problem(step)
    minutes = step["minutes"]
    unless (minutes.is_a?(Integer) && minutes.between?(5, 43_200)) || (lenient? && (minutes.nil? || (minutes.is_a?(Integer) && minutes.between?(0, 43_200))))
      return "minutes must be a whole number from 5 to 43200"
    end

    until_spec = step["until"]
    return step["timeout_next"].nil? ? nil : "timeout_next needs an until" if until_spec.nil?
    return "until must be an object" unless until_spec.is_a?(Hash)

    case until_spec["kind"]
    when "event" then (problem = event_problem(until_spec["event"])) && "until event #{problem}"
    when "opened", "clicked"
      wanted = until_spec["kind"] == "opened" ? "push" : "in_app"
      return if lenient? && !steps.key?(until_spec["step"])

      "until must name a #{wanted} step above it" unless steps.dig(until_spec["step"], "type") == wanted && above?(until_spec["step"], step["id"])
    else "until kind must be event, opened or clicked"
    end
  end

  def split_problem(step)
    return percent_problem(step["paths"]) if step["mode"] == "percent"
    return "mode must be condition or percent" unless step["mode"] == "condition"

    condition_problem(step["condition"])
  end

  def percent_problem(paths)
    return "paths must be a list of 2 or 3" unless paths.is_a?(Array) && paths.size.between?(2, 3) && paths.all?(Hash)
    # Before launch every path needs people; after it, one may go to 0 to send everyone down the winner.
    least = lenient? || status_in_database != "draft" ? 0 : 1
    whole = paths.all? { |p| p["percent"].is_a?(Integer) && p["percent"] >= least }
    return least.zero? ? "each path needs a whole percent" : "each path needs a whole percent of at least 1" unless whole

    "the percentages must add up to 100" unless paths.sum { |p| p["percent"] } == 100 || lenient?
  end

  def condition_problem(condition)
    return "condition must be an object" unless condition.is_a?(Hash)

    case condition["kind"]
    when "event"
      (problem = event_problem(condition["event"])) && (return "condition event #{problem}")
      return "days must be a whole number from 1 to 90" unless whole?(condition["days"], 1..90)

      "min_count must be a whole number of at least 1" unless whole?(condition["min_count"], 1..)
    when "segment" then (condition["segment_id"].nil? && lenient?) || segment?(condition["segment_id"]) ? nil : "names a segment that was not found"
    when "attribute" then attribute_problem(condition)
    when "platform"
      values = condition["values"]
      "values must be some of ios, android, web" unless values.is_a?(Array) && (values.any? || lenient?) && (values - PLATFORMS).empty?
    else "condition kind must be event, segment, attribute or platform"
    end
  end

  def attribute_problem(condition)
    return if lenient? && condition["key"].is_a?(String) && condition["key"].length <= 64
    return "the attribute key is not valid" unless condition["key"].is_a?(String) && condition["key"].match?(FIELD)
    return "op must be one of #{ATTRIBUTE_OPS.join(', ')}" unless ATTRIBUTE_OPS.include?(condition["op"])
    return if %w[exists not_exists].include?(condition["op"])

    "value must be a string, number or true/false" unless [String, Integer, Float, TrueClass, FalseClass].any? { |k| condition["value"].is_a?(k) }
  end

  def push_problem(step)
    return "title must be text of up to 255 characters" unless step["title"].nil? || (step["title"].is_a?(String) && step["title"].length <= 255)
    return "body must be text of up to 1000 characters" unless step["body"].nil? || (step["body"].is_a?(String) && step["body"].length <= 1000)
    return "data must be an object" unless step["data"].nil? || step["data"].is_a?(Hash)
    return "link_id must be a link id or null" unless step["link_id"].nil? || step["link_id"].is_a?(Integer)

    "quiet_hours must be true or false" unless [nil, true, false].include?(step["quiet_hours"])
  end

  def in_app_problem(step)
    return "template must be text" unless step["template"].is_a?(String)
    return "content must be an object" unless step["content"].is_a?(Hash)
    return "triggers must be a list" unless step["triggers"].nil? || step["triggers"].is_a?(Array)
    return "caps must be an object" unless step["caps"].nil? || step["caps"].is_a?(Hash)

    "valid_days must be a whole number from 1 to 30" unless step["valid_days"].is_a?(Integer) && step["valid_days"].between?(1, 30)
  end

  def set_attribute_problem(step)
    key_ok = step["key"].is_a?(String) && (step["key"].match?(ATTRIBUTE_KEY) || (lenient? && step["key"].length <= 48))
    return "key must start with journey_ and hold only a-z, 0-9 and _" unless key_ok
    return "value must be text of up to 255 characters" unless step["value"].is_a?(String) && step["value"].length <= 255

    "value cannot be empty" if step["value"].empty? && !lenient?
  end

  def event_problem(event)
    return "must be an object" unless event.is_a?(Hash)
    return "holds unknown fields" unless (event.keys - %w[name screen system filters]).empty?

    named = %w[name screen system].select { |k| event[k].present? }
    return (lenient? ? nil : "needs an event: a custom event, a screen or a built-in one") if named.empty?
    return "needs exactly one of name, screen or system" unless named.size == 1 && event[named.first].is_a?(String) && event[named.first].length <= 256
    return "system must be one of #{Experiments::Goal::SYSTEM.join(', ')}" if named == ["system"] && Experiments::Goal::SYSTEM.exclude?(event["system"])
    return "cannot filter a system event" if named == ["system"] && Array(event["filters"]).any?
    return "filters must be a list of at most 5" unless event["filters"].nil? || (event["filters"].is_a?(Array) && event["filters"].size <= 5)

    "has a filter that is not valid" unless Array(event["filters"]).all? { |f| filter?(f) || unfinished_filter?(f) }
  end

  # A draft may name a property not yet typed out; the rest of the filter must already be well formed.
  def unfinished_filter?(filter)
    lenient? && filter.is_a?(Hash) && (filter["field"].nil? || (filter["field"].is_a?(String) && filter["field"].length <= 64)) &&
      filter?(filter.merge("field" => "x"))
  end

  def filter?(filter)
    return false unless filter.is_a?(Hash) && filter["field"].is_a?(String) && filter["field"].match?(FIELD) && FILTER_OPS.include?(filter["op"])
    return (filter.keys - %w[field op]).empty? if %w[is_set is_not_set].include?(filter["op"])
    return filter["value"].is_a?(Array) && filter["value"].size == 2 && filter["value"].all?(Numeric) if filter["op"] == "between"

    [String, Integer, Float, TrueClass, FalseClass].any? { |k| filter["value"].is_a?(k) }
  end

  # A whole number in range; a draft may also leave it blank or at 0 while it is being filled in.
  def whole?(value, range) = (value.is_a?(Integer) && range.cover?(value)) || (lenient? && (value.nil? || value == 0))

  def segment?(hashid) = hashid.is_a?(String) && project.segments.active.find_by_hashid(hashid).present?

  def cycle?
    state = {}
    visit = lambda do |id|
      return false if id.nil? || state[id] == :done
      return true if state[id] == :open

      state[id] = :open
      found = pointers(steps[id]).values.any? { |next_id| visit.call(next_id) }
      state[id] = :done
      found
    end
    steps.keys.any? { |id| visit.call(id) }
  end

  # Whether `from` comes before `to` on some path, so a wait can only wait for a send it follows.
  def above?(from, to) = reachable_from(pointers(steps[from]).values).include?(to)

  def kept_after_launch
    locked = %w[control_group first_step start_at end_at].any? { |attr| will_save_change_to_attribute?(attr) }
    locked ||= %w[entry re_entry goals].any? { |attr| normalized(self[attr]) != normalized(attribute_in_database(attr)) }
    locked ||= steps_changed? && structure(steps) != structure(steps_was)
    errors.add(:base, LOCKED) if locked
  end

  # The map without what may change; percentages keep their paths so only the numbers may move.
  def structure(map)
    return map unless map.is_a?(Hash)

    map.transform_values do |s|
      next s unless s.is_a?(Hash)

      kept = s.except(*EDITABLE.fetch(s["type"], []), "campaign_id")
      kept = kept.merge("paths" => Array(s["paths"]).map { |p| p.is_a?(Hash) ? p.except("percent") : p }) if s["type"] == "split" && s["mode"] == "percent"
      normalized(kept)
    end
  end

  # A null and a missing key, and missing and empty filters, say the same thing; key order never matters to a Hash.
  def normalized(value)
    case value
    when Hash then value.to_h { |k, v| [k, normalized(v)] }.reject { |k, v| v.nil? || (k == "filters" && v == []) }
    when Array then value.map { |v| normalized(v) }
    else value
    end
  end
end
