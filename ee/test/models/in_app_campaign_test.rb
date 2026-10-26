require "test_helper"
require "sidekiq/testing"

class InAppCampaignTest < ActiveSupport::TestCase
  include InAppFixtures
  fixtures :instances, :projects, :visitors, :devices

  PNG = "\x89PNG\r\n\x1A\n".b.freeze

  setup do
    @project = projects(:one)
    clear_in_app_stamps(@project)
  end

  test "a draft may be incomplete" do
    draft = InAppCampaign.new(project: @project, name: "Idea")
    assert draft.valid?, draft.errors.full_messages.join(", ")
  end

  test "a draft still refuses a field of the wrong kind" do
    draft = InAppCampaign.new(project: @project, name: "Idea", content: "text", triggers: {})
    assert_not draft.valid?
    assert_equal %i[content triggers], draft.errors.attribute_names.sort
  end

  test "the definition a device receives passes the shared schema" do
    campaign = in_app_campaign(@project, caps: { "lifetime" => 3 }, end_at: 2.days.from_now, schedule: { "days" => [1, 2], "from" => "09:00", "to" => "21:00" })
    definition = campaign.definition
    assert_empty InAppDefinition.problems(definition)
    assert_equal campaign.hashid, definition["id"]
    assert_equal({ "session" => nil, "day" => nil, "week" => nil, "lifetime" => 3, "ignore_global" => false }, definition["caps"])
    assert_equal [1, 2], definition["schedule"]["days"]
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, definition["schedule"]["end_at"])
  end

  test "launch refuses what the schema refuses and leaves the campaign a draft" do
    campaign = in_app_campaign(@project, triggers: [])
    error = assert_raises(InAppCampaign::Refused) { campaign.launch! }
    assert_match(/triggers/, error.message)
    assert_equal "draft", campaign.reload.status
  end

  CLOSE = { "id" => "b1", "text" => "Go", "action" => { "type" => "close" } }.freeze
  REFUSED = {
    "an unsafe link" => { content: { "title" => "a", "buttons" => [CLOSE.merge("action" => { "type" => "open_url", "url" => "javascript:alert(1)" })] } },
    "a link hidden on a second line" => { content: { "title" => "a", "tap_action" => { "type" => "open_url", "url" => "https://a.example\njavascript:x" } } },
    "two buttons with one id" => { content: { "title" => "a", "buttons" => [CLOSE, CLOSE] } },
    "braces that are not a field" => { content: { "title" => "Hi {{ user.first-name }}" } },
    "an end before the start" => { start_at: Time.utc(2030, 1, 2), end_at: Time.utc(2030, 1, 1) },
    "a web link with no slashes, whose host a field could fill" => { content: { "title" => "a", 
"tap_action" => { "type" => "open_url", "url" => "https:{{ user.host }}/x" } } },
    "a web link with a slash too many, whose host a field could fill" => { content: { "title" => "a", 
"tap_action" => { "type" => "open_url", "url" => "https:///{{ user.host }}/p" } } },
    "a link that starts another app's intent" => { content: { "title" => "a", 
"tap_action" => { "type" => "open_url", "url" => "intent://scan/#Intent;end" } } },
    "a first seen date that does not exist" => { conditions: [{ "type" => "first_seen", "op" => "before", "value" => "2026-02-30T00:00:00Z" }] },
    "an alert nobody can dismiss with no button" => { template: "alert", 
content: { "title" => "a", "dismissible" => false, "tap_action" => { "type" => "close" } } },
    "a message nobody can dismiss with nothing to tap" => { content: { "title" => "a", "dismissible" => false } },
    "an unknown template" => { template: "carousel" }
  }.freeze

  REFUSED.each do |name, attrs|
    test "launch refuses #{name}" do
      campaign = in_app_campaign(@project, **attrs)
      assert_raises(InAppCampaign::Refused) { campaign.launch! }
    end
  end

  UNSAFE = CLOSE.merge("action" => { "type" => "open_url", "url" => "javascript:alert(1)" }).freeze
  HTTP_IMAGE = { "portrait" => "http://cdn.example/a.png", "landscape" => nil }.freeze
  SAID = {
    "The triggers need at least 1" => { triggers: [] },
    "Button 1 action is not valid" => { content: { "title" => "a", "buttons" => [UNSAFE] } },
    "Button 1 label cannot be empty" => { content: { "title" => "a", "buttons" => [CLOSE.merge("text" => "")] } },
    "The title cannot be longer than 256 characters" => { content: { "title" => "a" * 300 } },
    "The portrait image must be served over https" => { content: { "title" => "a", "image" => HTTP_IMAGE } },
    "The limit per day must be 20 or less" => { caps: { "day" => 21 } },
    "Trigger 1 is not valid" => { triggers: [{ "type" => "shake" }] }
  }.freeze

  SAID.each do |sentence, attrs|
    test "says: #{sentence}" do
      error = assert_raises(InAppCampaign::Refused) { in_app_campaign(@project, **attrs).launch! }
      assert_includes error.message.split("; "), sentence
      assert_no_match(%r{#/|regex|schema|property}, error.message)
    end
  end

  test "outside production, a picture this server handed out over http does not stop a launch" do
    ENV["S3_ASSET_PREFIX"] = "http://localhost:3000"
    image = { "portrait" => "http://localhost:3000/rails/active_storage/blobs/a.png", "landscape" => nil }
    assert in_app_campaign(@project, content: { "title" => "a", "image" => image }).launch!
    foreign = { "portrait" => "http://elsewhere.example/a.png", "landscape" => nil }
    assert_raises(InAppCampaign::Refused) { in_app_campaign(@project, content: { "title" => "a", "image" => foreign }).launch! }
  ensure
    ENV.delete("S3_ASSET_PREFIX")
  end

  test "a delay, a store button and a message that must be answered can be launched" do
    update = CLOSE.merge("action" => { "type" => "open_store" })
    campaign = in_app_campaign(@project, delay_seconds: 5, content: { "title" => "Update", "dismissible" => false, "buttons" => [update] })
    assert campaign.launch!
    assert_equal [5, false], [campaign.definition["delay_seconds"], campaign.definition["content"]["dismissible"]]
  end

  test "a field with a fallback and a line break in the message are allowed" do
    campaign = in_app_campaign(@project, content: { "title" => "Hi {{ user.first_name | default: \"there\" }}", "message" => "One\nTwo" })
    assert campaign.launch!
    assert_equal "live", campaign.status
  end

  test "launch goes live now, or scheduled when the start is ahead" do
    assert_equal "live", live_in_app_campaign(@project).status
    assert_equal "scheduled", live_in_app_campaign(@project, start_at: 1.day.from_now).status
  end

  test "a launched campaign cannot be launched again" do
    campaign = live_in_app_campaign(@project)
    assert_not campaign.launch!
  end

  test "a project runs at most fifty campaigns at once" do
    with_limit(InAppCampaign, :ACTIVE_LIMIT, 1) do
      live_in_app_campaign(@project)
      error = assert_raises(InAppCampaign::Refused) { in_app_campaign(@project).launch! }
      assert_match(/at once/, error.message)
    end
  end

  test "editing what a device sees raises the revision; a new name does not" do
    campaign = live_in_app_campaign(@project)
    campaign.update!(name: "Renamed")
    assert_equal 1, campaign.revision
    campaign.update!(priority: 5)
    assert_equal 2, campaign.revision
  end

  test "a draft keeps revision 1 however often it is edited" do
    campaign = in_app_campaign(@project)
    campaign.update!(priority: 5)
    assert_equal 1, campaign.revision
  end

  test "a live campaign refuses an edit that breaks the definition, and a new template" do
    campaign = live_in_app_campaign(@project)
    assert_not campaign.update(triggers: [])
    assert_not campaign.reload.update(template: "cover")
    assert_match(/cannot change/, campaign.errors.full_messages.join)
  end

  test "only a change a device can see moves the campaigns stamp" do
    before = InAppStamps.campaigns(@project.id)
    draft = in_app_campaign(@project)
    draft.update!(priority: 3)
    assert_equal before, InAppStamps.campaigns(@project.id)
    draft.launch!
    assert_not_equal before, InAppStamps.campaigns(@project.id)
  end

  test "a segment campaign freezes its segment and waits in preparing" do
    segment = Segment.create!(project: @project, name: "S", definition: SEGMENT_DEFINITION)
    campaign = in_app_campaign(@project, audience_type: "segment", segment: segment)
    Sidekiq::Testing.fake! do
      InAppMembershipPopulateJob.jobs.clear
      campaign.launch!
      assert_equal [[campaign.id]], InAppMembershipPopulateJob.jobs.pluck("args")
    end
    assert_equal "preparing", campaign.status
    assert_equal segment.definition_hash, campaign.segment_definition_hash
    assert_equal InAppMemberships.key_for(@project.id, segment.definition_hash, nil), campaign.segment_key
  end

  test "a segment audience needs a segment of the same project" do
    foreign = Segment.create!(project: projects(:two), name: "S", definition: SEGMENT_DEFINITION)
    assert_not InAppCampaign.new(project: @project, name: "n", audience_type: "segment").valid?
    assert_not InAppCampaign.new(project: @project, name: "n", audience_type: "segment", segment: foreign).valid?
  end

  private

  test "a campaign with no start of its own is checked as starting at launch" do
    campaign = travel_to(3.days.ago) { in_app_campaign(@project, end_at: 1.day.from_now) }
    error = assert_raises(InAppCampaign::Refused) { campaign.launch! }
    assert_match(/end/i, error.message)
    assert_equal ["draft", nil], campaign.reload.values_at(:status, :launched_at)
  end

  test "a campaign whose definition no longer holds can still be paused and ended" do
    campaign = live_in_app_campaign(@project)
    campaign.update_columns(triggers: [])
    assert campaign.reload.transition!(from: %w[live], to: "paused")
    assert campaign.end!
    assert_equal "ended", campaign.reload.status
  end

  test "launches are counted under one lock for the project" do
    campaign = in_app_campaign(@project)
    locked = []
    campaign.project.stub(:with_lock, ->(&block) { locked << :project && block.call }) { campaign.launch! }
    assert_equal [:project], locked
  end

  test "an archived segment is refused at launch" do
    segment = Segment.create!(project: @project, name: "S", definition: SEGMENT_DEFINITION, archived: true)
    campaign = in_app_campaign(@project, audience_type: "segment", segment: segment)
    assert_raises(InAppCampaign::Refused) { campaign.launch! }
  end

  test "a segment audience with no segment is refused at launch" do
    segment = Segment.create!(project: @project, name: "S", definition: SEGMENT_DEFINITION)
    campaign = in_app_campaign(@project, audience_type: "segment", segment: segment)
    campaign.update_columns(segment_id: nil)
    assert_raises(InAppCampaign::Refused) { campaign.reload.launch! }
  end

  BIG = Array.new(10) { { "type" => "user_attribute", "key" => "k", "op" => "eq", "value" => "v" * 2_000 } }.freeze
  NOT_EVEN_A_DRAFT = { "over 16 KB" => { conditions: BIG }, "with a delay over an hour" => { delay_seconds: 3601 }, "with priority 11" => { priority: 11 },
                       "with no priority" => { priority: nil }, "with a priority beyond any number stored" => { priority: 10**12 } }.freeze

  NOT_EVEN_A_DRAFT.each do |name, attrs|
    test "a campaign #{name} cannot be saved, even as a draft" do
      campaign = InAppCampaign.new({ project: @project, name: "n", content: CONTENT.dup, triggers: [] }.merge(attrs))
      assert_not campaign.valid?
    rescue ActiveModel::RangeError
      pass
    end
  end

  test "an alert keeps no picture, and gets its upload back with another template" do
    campaign = in_app_campaign(@project)
    campaign.portrait_image.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "a.png", content_type: "image/png")
    campaign.update!(template: "alert", content: CONTENT.merge("image" => { "portrait" => nil, "landscape" => nil }))
    assert_nil campaign.reload.content.dig("image", "portrait")
    assert campaign.launch!
    assert campaign.portrait_image.attached?
  end

  test "deleting a draft sends no device back to sync" do
    draft = in_app_campaign(@project)
    stamp = InAppStamps.campaigns(@project.id)
    travel(1.second) { draft.destroy! }
    assert_equal stamp, InAppStamps.campaigns(@project.id)
  end

  test "an app link and a field after the site are still allowed" do
    links = ["myapp://cart/{{ user.id }}", "https://shop.example/{{ user.id }}?a={{ event.sku }}"]
    links.each do |url|
      campaign = in_app_campaign(@project, content: CONTENT.merge("tap_action" => { "type" => "open_url", "url" => url }))
      assert campaign.launch!, url
    end
  end

  test "a campaign may ask a question of each kind" do
    [STARS, CHOICE].each do |question|
      campaign = in_app_campaign(@project, content: asking(question))
      assert campaign.launch!, question["type"]
      assert_equal question, campaign.definition.dig("content", "question")
    end
    assert in_app_campaign(@project, template: "footer", content: asking(STARS, dismissible: false)).launch!
    assert_nil in_app_campaign(@project).definition.dig("content", "question")
  end

  QUESTION_REFUSED = {
    "with buttons as well" => { content: { "question" => STARS, "buttons" => [CLOSE] } },
    "with a tap action as well" => { content: { "question" => STARS, "tap_action" => { "type" => "close" } } },
    "of a kind nobody knows" => { content: { "question" => STARS.merge("type" => "slider") } },
    "with one option" => { content: { "question" => CHOICE.merge("options" => CHOICE["options"].first(1)) } },
    "with six options" => { content: { "question" => CHOICE.merge("options" => Array.new(6) { |i| { "id" => "o#{i}", "text" => "Option" } }) } },
    "with two options of one id" => { content: { "question" => CHOICE.merge("options" => [CHOICE["options"].first] * 2) } },
    "with options for stars" => { content: { "question" => STARS.merge("options" => CHOICE["options"]) } },
    "from 0 to 10, which is not offered" => { content: { "question" => STARS.merge("type" => "nps", "review_from" => nil) } },
    "with a review step on a list of options" => { content: { "question" => CHOICE.merge("review_from" => 4) } },
    "in an alert" => { template: "alert", content: { "question" => STARS } },
    "in a picture-only message" => { template: "interstitial_image", content: { "question" => STARS } },
    "whose follow-up splits at the highest answer" => { content: { "question" => STARS.merge("comment" => STARS["comment"].merge("split" => 5)) } },
    "whose follow-up splits a list of options" => { content: { "question" => CHOICE.merge("comment" => { "split" => 1, "low" => "a", "high" => nil }) } }
  }.freeze

  QUESTION_REFUSED.each do |name, attrs|
    test "launch refuses a question #{name}" do
      content = CONTENT.merge(attrs.fetch(:content))
      campaign = in_app_campaign(@project, **attrs, content: content)
      assert_raises(InAppCampaign::Refused) { campaign.launch! }
    end
  end

  test "after launch the question keeps its kind, and cannot be added or removed" do
    campaign = live_in_app_campaign(@project, content: asking)
    assert campaign.update(content: asking(STARS.merge("thanks" => "Cheers")))
    assert_not campaign.update(content: asking(CHOICE))
    assert_not campaign.update(content: CONTENT.dup)
    plain = live_in_app_campaign(@project)
    assert_not plain.update(content: asking)
  end

  def with_limit(owner, name, value)
    old = owner.const_get(name)
    owner.send(:remove_const, name)
    owner.const_set(name, value)
    yield
  ensure
    owner.send(:remove_const, name)
    owner.const_set(name, old)
  end

  B = { "id" => "b", "content" => { "title" => "Hi", "message" => "Back again" } }.freeze

  test "an experiment is shaped: a control percent, a goal with a window, up to two variants named b then c" do
    draft = InAppCampaign.new(project: @project, name: "Idea", control_group: 51)
    assert_not draft.valid?
    draft.control_group = 10
    draft.conversion = { "event" => "checkout", "window_hours" => 48 }
    assert_not draft.valid?
    draft.conversion = { "event" => "in_app_viewed", "window_hours" => 72 }
    assert_not draft.valid?
    draft.conversion = { "event" => "checkout", "screen" => "Cart", "window_hours" => 72 }
    assert_not draft.valid?
    draft.conversion = { "screen" => "Checkout", "window_hours" => 72 }
    assert draft.valid?, draft.errors.full_messages.join(", ")
    draft.conversion = { "event" => "checkout", "window_hours" => 72 }
    draft.variants = [B, B]
    assert_not draft.valid?
    draft.variants = [B, B.merge("id" => "c"), B]
    assert_not draft.valid?
    draft.variants = [B, B.merge("id" => "c")]
    assert draft.valid?, draft.errors.full_messages.join(", ")
    assert_equal %w[a b c], draft.variant_ids
    assert draft.experiment?
    assert_not InAppCampaign.new(project: @project, name: "Plain").experiment?
  end

  test "a variant is its own definition, checked at launch like the campaign's content" do
    campaign = in_app_campaign(@project, variants: [B.merge("content" => { "title" => "x" * 300 })])
    error = assert_raises(InAppCampaign::Refused) { campaign.launch! }
    assert_match(/Variant B: The title/, error.message)

    campaign.update!(variants: [B])
    campaign.launch!
    assert_equal "Hi", campaign.definition_for("b")["content"]["title"]
    assert_equal "Hello", campaign.definition_for("a")["content"]["title"]
    assert_equal "Hello", campaign.definition_for("zzz")["content"]["title"]
    assert_nil campaign.definition_for("b")["variants"]
    assert_empty InAppDefinition.problems(campaign.definition_for("b"))
  end

  test "a variant may also carry html, checked at launch like the campaign's own" do
    bad = { "html" => '<a href="javascript:x">go</a>', "layout" => "modal" }
    campaign = in_app_campaign(@project, template: "html", content: { "html" => "<p>ok</p>", "layout" => "modal" }, variants: [B.merge("content" => bad)])
    error = assert_raises(InAppCampaign::Refused) { campaign.launch! }
    assert_match(/Variant B:/, error.message)

    campaign.update!(variants: [B.merge("content" => { "html" => "<p>fine</p>", "layout" => "banner_top" })])
    assert campaign.launch!
    assert_equal "banner_top", campaign.definition_for("b")["content"]["layout"]
  end

  test "a large html body does not count toward the 16 KB limit, but other bloat still does" do
    campaign = in_app_campaign(@project, template: "html", content: { "html" => "<p>#{'a' * (60 * 1024)}</p>", "layout" => "modal" })
    assert campaign.valid?, campaign.errors.full_messages.join(", ")
    campaign.conditions = BIG
    assert_not campaign.valid?
    assert_includes campaign.errors[:base], "The campaign is larger than 16 KB"
  end

  test "a draft cannot hold html over 64 KB, since it skips the schema and definition_holds" do
    html = "<p>#{'a' * (65 * 1024)}</p>"
    draft = InAppCampaign.new(project: @project, name: "Idea", template: "html", content: { "html" => html, "layout" => "modal" },
                               triggers: InAppFixtures::TRIGGERS.map(&:dup))
    assert_not draft.valid?
    assert_includes draft.errors[:base], "The HTML is larger than 64 KB"

    variant_draft = InAppCampaign.new(project: @project, name: "Idea", content: CONTENT.dup, triggers: InAppFixtures::TRIGGERS.map(&:dup),
                                       variants: [B.merge("content" => { "html" => html, "layout" => "modal" })])
    assert_not variant_draft.valid?
    assert_includes variant_draft.errors[:variants], "each HTML must be under 64 KB"
  end

  test "after launch the split is fixed, while variant content and the goal can change" do
    campaign = live_in_app_campaign(@project, control_group: 10, variants: [B])
    assert_not campaign.update(control_group: 20)
    assert_not campaign.update(variants: [B, B.merge("id" => "c")])
    assert_not campaign.update(variants: nil)
    campaign.reload
    assert campaign.update(variants: [B.merge("content" => { "title" => "New", "message" => "Text" })], conversion: { "event" => "buy", "window_hours" => 24 })
    assert_equal 2, campaign.revision
  end

  test "a variant may reword the question but not ask another, and shows A's pictures" do
    campaign = in_app_campaign(@project, content: asking, variants: [B.merge("content" => B["content"].merge("question" => STARS.merge("thanks" => "Cheers")))])
    assert campaign.valid?, campaign.errors.full_messages.join(", ")
    campaign.variants = [B.merge("content" => B["content"].merge("question" => CHOICE))]
    assert_not campaign.valid?
    campaign.variants = [B]
    assert_not campaign.valid?, "a variant without the question"
    campaign.variants = [B.merge("extra" => 1, "content" => B["content"].merge("question" => STARS))]
    assert_not campaign.valid?

    plain = in_app_campaign(@project, content: CONTENT.merge("image" => { "portrait" => "https://a.example/p.png", "landscape" => nil }),
                                      variants: [B.merge("content" => B["content"].merge("image" => { "portrait" => "https://old.example/x.png" }))])
    assert_equal "https://a.example/p.png", plain.definition_for("b")["content"]["image"]["portrait"]
  end

  def media_file(bytes = PNG, content_type: "image/png", name: "x.png")
    tempfile = Tempfile.new(name, binmode: true)
    tempfile.write(bytes)
    tempfile.rewind
    ActionDispatch::Http::UploadedFile.new(tempfile: tempfile, filename: name, type: content_type)
  end

  # with_lock reloads the row (and so its associations) before the cap is checked, the way launch! re-checks its own
  # caps: an object loaded before other uploads landed must still see them, not the count it had when it was loaded.
  test "the media count cap is re-checked after the row lock, not from a stale in-memory count" do
    campaign = in_app_campaign(@project)
    stale = InAppCampaign.find(campaign.id)
    stale.media.attachments.load
    InAppCampaign::MEDIA_COUNT_LIMIT.times { |i| campaign.media.attach(io: StringIO.new(PNG), filename: "p#{i}.png", content_type: "image/png") }

    assert_nil stale.attach_media(media_file)
    assert_includes stale.errors[:media], "a campaign can hold at most #{InAppCampaign::MEDIA_COUNT_LIMIT} files"
  end

  test "duplicate with a variant copies only that variant's media, not a's or the other variant's" do
    campaign = in_app_campaign(@project)
    a_blob = campaign.media.attach(io: StringIO.new(PNG), filename: "a.png", content_type: "image/png") && campaign.media.blobs.last
    b_blob = campaign.media.attach(io: StringIO.new(PNG), filename: "b.png", content_type: "image/png") && campaign.media.blobs.last
    c_blob = campaign.media.attach(io: StringIO.new(PNG), filename: "c.png", content_type: "image/png") && campaign.media.blobs.last
    campaign.update!(content: campaign.content.merge("html" => "<img src=\"#{AssetService.absolute_url(a_blob)}\">"),
                     variants: [{ "id" => "b", "content" => { "html" => "<img src=\"#{AssetService.absolute_url(b_blob)}\">" } },
                                { "id" => "c", "content" => { "html" => "<img src=\"#{AssetService.absolute_url(c_blob)}\">" } }])

    copy = InAppCampaign.new(project: @project, name: "copy")
    copy.assign_attributes(campaign.slice(*InAppCampaign::DEFINITION_FIELDS, *InAppCampaign::EXPERIMENT_FIELDS, "audience_type"))
    copy.assign_attributes(content: campaign.variant_content("b"), variants: nil, control_group: nil, conversion: nil)
    assert copy.save
    assert copy.copy_images_from(campaign)
    assert copy.copy_media_from(campaign)

    assert_equal 1, copy.media.count
    assert_equal b_blob.filename.to_s, copy.media.blobs.first.filename.to_s
    assert_includes copy.content["html"], AssetService.absolute_url(copy.media.blobs.first)
    assert_not_includes copy.content["html"], AssetService.absolute_url(b_blob)
  end

  test "accepts MP4s branded avc1, iso5, iso6 and dash, which Marcel alone calls QuickTime" do
    campaign = in_app_campaign(@project)
    %w[avc1 iso5 iso6 dash].each do |brand|
      mp4 = "\x00\x00\x00\x18ftyp#{brand}\x00\x00\x02\x00isomavc1".b + ("\x00" * 64).b
      blob = campaign.attach_media(media_file(mp4, content_type: "video/mp4", name: "#{brand}.mp4"))
      assert blob, "#{brand}: #{campaign.errors.full_messages.join(', ')}"
      assert_equal "video/mp4", blob.content_type
    end
  end

  test "an upload queues no analysis, whose blob touch would bump the lock_version it returned" do
    campaign = in_app_campaign(@project)
    queued = 0
    ActiveStorage::AnalyzeJob.stub(:perform_later, ->(*) { queued += 1 }) { assert campaign.attach_media(media_file) }
    assert_equal 0, queued
  end

  test "an image upload or a copy queues no analysis either" do
    campaign = in_app_campaign(@project)
    queued = 0
    ActiveStorage::AnalyzeJob.stub(:perform_later, ->(*) { queued += 1 }) do
      assert campaign.attach_image("portrait", media_file)
      copy = InAppCampaign.new(project: @project, name: "copy")
      copy.assign_attributes(campaign.slice(*InAppCampaign::DEFINITION_FIELDS, "audience_type"))
      assert copy.save
      assert copy.copy_images_from(campaign)
      assert copy.portrait_image.attached?
    end
    assert_equal 0, queued
  end

  test "attach_media returns the blob it uploaded, not the newest attached one" do
    campaign = in_app_campaign(@project)
    other = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(PNG), filename: "other.png", content_type: "image/png")
    ActiveStorage::Blob.where(id: other.id).update_all(id: other.id + 1_000_000)
    campaign.media.attach(ActiveStorage::Blob.find(other.id + 1_000_000))

    blob = campaign.attach_media(media_file(name: "mine.png"))
    assert_equal "mine.png", blob.filename.to_s
    assert_includes campaign.reload.media.blobs.map(&:id), blob.id
  end

  test "a refused or stale attach_media leaves no stray blob" do
    campaign = in_app_campaign(@project)
    InAppCampaign::MEDIA_COUNT_LIMIT.times { |i| campaign.media.attach(io: StringIO.new(PNG), filename: "p#{i}.png", content_type: "image/png") }
    assert_no_difference("ActiveStorage::Blob.count") { assert_nil campaign.attach_media(media_file) }

    fresh = in_app_campaign(@project)
    assert_no_difference("ActiveStorage::Blob.count") do
      assert_raises(ActiveRecord::StaleObjectError) { fresh.attach_media(media_file, expected_version: fresh.lock_version + 1) }
    end
  end

  test "media is matched on its path, so html stored under another host still counts as in use and is rewritten" do
    campaign = in_app_campaign(@project)
    blob = campaign.media.attach(io: StringIO.new(PNG), filename: "a.png", content_type: "image/png") && campaign.media.blobs.last
    campaign.update!(content: campaign.content.merge("html" => "<img src=\"https://old-cdn.example#{AssetService.path(blob)}\">"))
    assert campaign.media_in_use?(blob)

    copy = InAppCampaign.new(project: @project, name: "copy")
    copy.assign_attributes(campaign.slice(*InAppCampaign::DEFINITION_FIELDS, "audience_type"))
    assert copy.save
    assert copy.copy_media_from(campaign)
    assert_equal "<img src=\"https://old-cdn.example#{AssetService.path(copy.media.blobs.first)}\">", copy.content["html"]
  end

  test "media named with an ampersand, or served in proxy form, is in use, and a copy rewrites both forms keeping the host" do
    campaign = in_app_campaign(@project)
    blob = campaign.media.attach(io: StringIO.new(PNG), filename: "a&b.png", content_type: "image/png") && campaign.media.blobs.last
    redirect = "https://a.example#{AssetService.path(blob)}"
    proxy = "https://b.example#{AssetService.path(blob).sub('/redirect/', '/proxy/')}"
    campaign.update!(content: campaign.content.merge("html" => "<img src=\"#{redirect}\">"))
    assert campaign.media_in_use?(blob)
    campaign.update!(content: campaign.content.merge("html" => "<img src=\"#{proxy}\"><video src='#{redirect}'>"))
    assert campaign.media_in_use?(blob)

    copy = InAppCampaign.new(project: @project, name: "copy")
    copy.assign_attributes(campaign.slice(*InAppCampaign::DEFINITION_FIELDS, "audience_type"))
    assert copy.save
    assert copy.copy_media_from(campaign)
    path = AssetService.path(copy.media.blobs.first)
    assert_equal "<img src=\"https://b.example#{path.sub('/redirect/', '/proxy/')}\"><video src='https://a.example#{path}'>", copy.content["html"]
  end
end
