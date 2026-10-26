require "test_helper"
require "sidekiq/testing"

class SegmentExportJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :users, :instance_roles, :devices, :visitors

  DEFINITION = { "version" => 1, "operator" => "or", "groups" => [{ "operator" => "and", "conditions" => [
    { "type" => "event", "event_name" => "checkout", "window" => { "last_days" => 30 } }
  ] }] }.freeze

  setup do
    @project = projects(:one)
    @segment = Segment.create!(project: @project, name: "Buyers", definition: DEFINITION)
    @export = SegmentExport.create!(project: @project, segment: @segment, user: users(:admin_user),
                                    definition: @segment.definition, definition_hash: @segment.definition_hash)
    @visitors = Visitor.where(project_id: @project.id).order(:id).limit(2).to_a
    @manifest = Segments::Results::Manifest.new(result_id: "9" * 32, project_id: @project.id, persons: 2, devices: 2, rows: 2, incomplete: false)
  end

  def pages(*batches)
    calls = batches.dup
    lambda do |**kwargs|
      @first_page_call ||= kwargs.slice(:limit, :max)
      calls.shift || { users: [], next_after: nil }
    end
  end

  def run_job(members:)
    Segments::Results.stub(:for, @manifest) do
      Segments::Results.stub(:fetch!, @manifest) do
        Segments::Members.stub(:page, members) { SegmentExportJob.new.perform(@export.id) }
      end
    end
  end

  test "writes a CSV with one row per member, marks the export ready and schedules the purge" do
    users = @visitors.map { |v| VisitorSerializer.serialize(v, slim: true).merge("person_key" => "v:#{v.id}") }
    run_job(members: pages({ users: users.first(1), next_after: @visitors.first.id }, { users: users.last(1), next_after: nil }))
    @export.reload
    assert_equal "ready", @export.status
    assert_equal 2, @export.rows
    assert_equal SegmentExportJob::PAGE, @first_page_call[:limit]
    assert_equal SegmentExportJob::PAGE, @first_page_call[:max]
    csv = CSV.parse(@export.file.download, headers: true)
    assert_equal %w[person_key visitor_uuid sdk_identifier sdk_attributes created_at], csv.headers
    assert_equal 2, csv.size
  end

  test "uses the definition captured at request time, not the segment's current one" do
    @segment.update!(definition: DEFINITION.deep_merge("groups" => [{ "operator" => "and", "conditions" => [
      { "type" => "event", "event_name" => "refund", "window" => { "last_days" => 30 } }
    ] }]))
    seen = nil
    lookup = lambda do |definition:, **|
      seen = definition.digest
      @manifest
    end
    Segments::Results.stub(:for, lookup) do
      Segments::Results.stub(:fetch!, @manifest) do
        Segments::Members.stub(:page, pages) { SegmentExportJob.new.perform(@export.id) }
      end
    end
    assert_equal @export.definition_hash, seen
  end

  test "passes the export's segment_id so in_list conditions resolve at export time" do
    seen = nil
    lookup = lambda do |segment_id:, **|
      seen = segment_id
      @manifest
    end
    Segments::Results.stub(:for, lookup) do
      Segments::Results.stub(:fetch!, @manifest) do
        Segments::Members.stub(:page, pages) { SegmentExportJob.new.perform(@export.id) }
      end
    end
    assert_equal @segment.id, seen
  end

  test "a busy evaluation re-queues the export a bounded number of times, then fails it" do
    Sidekiq::Testing.fake! do
      SegmentExportJob.clear
      Segments::Results.stub(:for, ->(*) { raise Segments::Busy }) do
        SegmentExportJob.new.perform(@export.id)
        assert_equal "pending", @export.reload.status
        assert_equal [[@export.id, 1]], SegmentExportJob.jobs.map { |j| j["args"] }
        assert_raises(Segments::Busy) { SegmentExportJob.new.perform(@export.id, SegmentExportJob::MAX_BUSY_RETRIES) }
      end
    end
    assert_equal %w[failed Segments::Busy], @export.reload.values_at(:status, :error)
  end

  test "a result that expires mid-export fails the export instead of delivering a short file" do
    Segments::Results.stub(:for, @manifest) do
      Segments::Results.stub(:fetch!, ->(*) { raise Segments::ResultExpired }) do
        Segments::Members.stub(:page, pages) do
          assert_raises(Segments::ResultExpired) { SegmentExportJob.new.perform(@export.id) }
        end
      end
    end
    assert_equal "failed", @export.reload.status
    assert_not @export.file.attached?
  end

  FailingMail = Struct.new(:message) do
    def deliver_now = raise message
  end

  test "a mail delivery failure does not fail the job and leaves the export ready with the purge scheduled" do
    users = @visitors.map { |v| VisitorSerializer.serialize(v, slim: true).merge("person_key" => "v:#{v.id}") }
    purge_args = nil
    PurgeSegmentExportJob.stub(:perform_in, ->(*args) { purge_args = args }) do
      SegmentExportMailer.stub(:ready, ->(*) { FailingMail.new("smtp down") }) do
        run_job(members: pages({ users: users, next_after: nil }))
      end
    end
    @export.reload
    assert_equal "ready", @export.status
    assert @export.file.attached?
    assert_equal [SegmentExportJob::KEEP_FOR, @export.id], purge_args
  end

  test "a purge-scheduling failure fails the export and purges the already-attached file" do
    users = @visitors.map { |v| VisitorSerializer.serialize(v, slim: true).merge("person_key" => "v:#{v.id}") }
    PurgeSegmentExportJob.stub(:perform_in, ->(*) { raise "redis down" }) do
      assert_raises(RuntimeError) { run_job(members: pages({ users: users, next_after: nil })) }
    end
    @export.reload
    assert_equal "failed", @export.status
    assert_not @export.file.attached?
  end

  test "a formula-like identifier is written with a leading apostrophe" do
    malicious = VisitorSerializer.serialize(@visitors.first, slim: true)
                                  .merge("person_key" => "v:#{@visitors.first.id}", "sdk_identifier" => '=HYPERLINK("http://x")')
    normal = VisitorSerializer.serialize(@visitors.last, slim: true)
                               .merge("person_key" => "v:#{@visitors.last.id}", "sdk_identifier" => "person@example.com")
    run_job(members: pages({ users: [malicious, normal], next_after: nil }))
    csv = CSV.parse(@export.reload.file.download, headers: true)
    assert_equal "'=HYPERLINK(\"http://x\")", csv[0]["sdk_identifier"]
    assert_equal "person@example.com", csv[1]["sdk_identifier"]
  end

  test "a visitor without sdk_attributes writes an empty cell, not the literal null" do
    u = VisitorSerializer.serialize(@visitors.first, slim: true).merge("person_key" => "v:#{@visitors.first.id}", "sdk_attributes" => nil)
    run_job(members: pages({ users: [u], next_after: nil }))
    assert_not_includes @export.reload.file.download, "null"
  end
end
