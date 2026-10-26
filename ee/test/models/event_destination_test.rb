require "test_helper"

class EventDestinationTest < ActiveSupport::TestCase
  include EventStreamTestHelper
  fixtures :instances, :users, :instance_roles, :projects

  setup do
    @project = projects(:one)
  end

  def build(attrs = {})
    EventDestination.new({ project: @project, name: "crm", kind: "webhook", settings: { "url" => "https://hooks.example.com/in" } }.merge(attrs))
  end

  test "valid webhook destination with defaults" do
    d = build
    assert d.valid?, d.errors.full_messages.join(", ")
    assert_equal "enabled", d.status
    assert_equal 100, d.batch_size
    assert_equal 4, d.concurrency
    assert_equal EventDestination::DEFAULT_EVENT_TYPES, d.event_types
    assert_not d.include_ip
  end

  test "rejects unknown kind, bad url, and out of range sizes" do
    assert_not build(kind: "kafka").valid?
    assert_not build(settings: { "url" => "ftp://x" }).valid?
    assert_not build(batch_size: 0).valid?
    assert_not build(batch_size: 501).valid?
    assert_not build(concurrency: 17).valid?
    assert_not build(event_types: %w[install bogus]).valid?
  end

  test "custom headers must be a map of strings" do
    d = build
    d.credentials_hash = { "headers" => { "X-Api-Key" => %w[a b] } }
    assert_not d.valid?
    d.credentials_hash = { "headers" => { "X-Api-Key" => "k1" } }
    assert d.valid?, d.errors.full_messages.join(", ")
  end

  test "a run that delivered some events but failed keeps its failure clock running" do
    d = build
    d.save!
    d.record_failure!("boom")
    since = d.failing_since
    d.record_partial!(cursor: { events_at: Time.current, events_id: "e1" }, delivered: 1)
    assert_equal since.to_i, d.reload.failing_since.to_i
    assert_equal 1, d.consecutive_failures
    assert_equal 1, d.delivered_count
  end

  test "s3 destination requires bucket, region, and on SaaS its own keys" do
    assert_not build(kind: "s3", settings: {}).valid?
    s3 = build(kind: "s3", settings: { "bucket" => "b", "region" => "us-east-1" })
    assert_not s3.valid?
    assert_includes s3.errors[:credentials].join, "required"
    s3.credentials_hash = { "access_key_id" => "AKIA", "secret_access_key" => "s" }
    assert s3.valid?
  end

  test "self-hosted s3 may rely on the deployment's credential chain" do
    with_self_hosted { assert build(kind: "s3", settings: { "bucket" => "b", "region" => "us-east-1" }).valid? }
  end

  test "s3 custom endpoints resolving to private addresses are invalid on SaaS but allowed self-hosted" do
    s3 = lambda do |endpoint|
      build(kind: "s3", settings: { "bucket" => "b", "region" => "r", "endpoint" => endpoint })
        .tap { |d| d.credentials_hash = { "access_key_id" => "AKIA", "secret_access_key" => "s" } }
    end
    assert s3.call("https://s3.eu-central-1.wasabisys.com").valid?
    assert s3.call("https://fsn1.your-objectstorage.com").valid?
    assert s3.call("https://storage.custom-provider.example").valid?
    assert_not s3.call("http://storage.custom-provider.example").valid?
    assert_not s3.call("https://").valid?
    with_resolver([]) { assert_not s3.call("https://unknown.example").valid? }
    with_resolver(["10.0.0.5"]) { assert_not s3.call("https://s3.wasabisys.com").valid? }
    with_resolver(["::"]) do
      assert_not s3.call("https://storage.custom-provider.example").valid?
      with_self_hosted { assert s3.call("https://storage.custom-provider.example").valid? }
    end
    with_self_hosted { assert s3.call("http://minio:9000").valid? }
  end

  test "webhook urls resolving to private addresses are invalid on SaaS but allowed self-hosted" do
    with_resolver(["10.0.0.5"]) do
      assert_not build.valid?
      with_self_hosted { assert build.valid? }
    end
  end

  test "credentials are stored encrypted and round-trip as a hash" do
    d = build
    d.credentials_hash = { "headers" => { "Authorization" => "Bearer abc" } }
    d.save!
    assert_equal({ "headers" => { "Authorization" => "Bearer abc" } }, d.reload.credentials_hash)
    raw = EventDestination.connection.select_value("SELECT credentials FROM event_destinations WHERE id = #{d.id}").to_s
    assert_not_includes raw, "Bearer abc"
  end

  test "failure backoff grows, pause after 24h, resume clears" do
    d = build
    d.save!
    d.record_failure!("boom")
    assert_equal 1, d.consecutive_failures
    assert d.backoff_until > Time.current
    assert d.failing_since.present?

    d.update!(failing_since: 25.hours.ago)
    d.record_failure!("boom again")
    assert d.paused?
    assert_equal "boom again", d.last_error

    d.resume!
    assert d.enabled?
    assert_nil d.failing_since
    assert_equal 0, d.consecutive_failures
  end

  test "record_success advances the bookmark and clears failure state" do
    d = build
    d.save!
    d.record_failure!("x")
    t = Time.current.change(usec: 123_000)
    d.record_success!(cursor: { events_at: t, events_id: "e9" }, delivered: 3)
    assert_equal "e9", d.events_cursor_id
    assert_in_delta t.to_f, d.events_cursor_at.to_f, 0.001
    assert_equal 3, d.delivered_count
    assert_nil d.failing_since
    assert_equal 0, d.consecutive_failures
  end

  test "due? respects backoff and s3 flush interval" do
    w = build
    w.save!
    assert w.due?(Time.current)
    w.update!(backoff_until: 1.minute.from_now)
    assert_not w.due?(Time.current)

    s = build(kind: "s3", settings: { "bucket" => "b", "region" => "eu-central-1" })
    s.credentials_hash = { "access_key_id" => "AKIA", "secret_access_key" => "s" }
    s.save!
    s.update!(last_attempt_at: Time.current)
    assert s.due?(Time.current), "a successful attempt does not postpone an unfinished backlog"
    s.record_idle!(cursor: {})
    assert_not s.due?(Time.current)
    assert s.due?(5.minutes.from_now)
  end
end
