require "test_helper"
require "sidekiq/testing"
require_relative "../../../test/integration/auth_test_helper"

class SegmentsApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  fixtures :instances, :users, :instance_roles, :projects

  DEFINITION = { version: 1, operator: "or", groups: [{ operator: "and", conditions: [
    { type: "event", event_name: "checkout", count: 2, window: { last_days: 30 } }
  ] }] }.freeze

  PURCHASE_DEFINITION = { version: 1, operator: "or", groups: [{ operator: "and", conditions: [
    { type: "purchase", window: { last_days: 30 } }
  ] }] }.freeze

  setup do
    @project = projects(:one)
    @admin = doorkeeper_headers_for(users(:admin_user))
    @member = doorkeeper_headers_for(users(:member_user))
  end

  def base = "#{API_PREFIX}/projects/#{@project.id}/segments"

  def create!(headers: @admin, **extra)
    post base, params: { name: "Buyers", definition: DEFINITION }.merge(extra), headers: headers, as: :json
    JSON.parse(response.body)
  end

  test "a cursor pinned to one segment cannot page another segment's members" do
    a = create!["segment"]["id"]
    b = create!(name: "Other", definition: PURCHASE_DEFINITION.merge(groups: [{ operator: "and", conditions: [
      { type: "event", event_name: "signup", count: 1, window: { last_days: 30 } }
    ] }]))["segment"]["id"]
    seg_a = Segment.find_by_hashid(a)
    manifest = Segments::Results::Manifest.new(result_id: "a" * 32, project_id: @project.id, definition_hash: seg_a.definition_hash,
                                               list_generation: nil, persons: 0, devices: 0, rows: 0, incomplete: false)
    cursor = Segments::Members.encode_cursor(manifest.result_id, 0)
    Segments::Results.stub(:fetch!, manifest) do
      Segments::Members.stub(:page, { users: [], next_after: nil }) do
        post "#{base}/#{a}/users", params: { cursor: cursor }, headers: @admin, as: :json
        assert_response :ok
        post "#{base}/#{b}/users", params: { cursor: cursor }, headers: @admin, as: :json
        assert_response :gone
      end
    end
  end

  test "admin creates a segment and the canonical definition comes back" do
    body = create!
    assert_response :created
    seg = body["segment"]
    assert_equal "Buyers", seg["name"]
    assert_equal 2, seg["definition"]["groups"][0]["conditions"][0]["count"]
    assert_equal false, seg["archived"]
    assert_match(/\A\h{64}\z/, seg["definition_hash"])
  end

  test "an invalid definition is a 422 naming the condition path" do
    post base, params: { name: "Bad", definition: { version: 1, operator: "or", groups: [{ operator: "and", conditions: [{ type: "nope" }] }] } },
               headers: @admin, as: :json
    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["error"], "groups[0].conditions[0]"
  end

  test "members read and write segments" do
    id = create!["segment"]["id"]
    get base, headers: @member
    assert_response :ok
    assert_equal 1, JSON.parse(response.body)["segments"].size
    get "#{base}/#{id}", headers: @member
    assert_response :ok
    post base, params: { name: "x", definition: DEFINITION }, headers: @member, as: :json
    assert_response :created
    patch "#{base}/#{id}", params: { name: "renamed" }, headers: @member, as: :json
    assert_response :ok
    delete "#{base}/#{id}", headers: @member
    assert_response :ok
  end

  test "delete succeeds even when the stored definition has aged past retention" do
    id = create!["segment"]["id"]
    segment = Segment.find_by_hashid(id)
    aged = { "version" => 1, "operator" => "and", "groups" => [
      { "operator" => "and", "conditions" => [
        { "type" => "event", "event_name" => "checkout",
          "window" => { "from" => (Date.current - 400).iso8601, "to" => (Date.current - 390).iso8601 } }
      ] }
    ] }
    segment.update_columns(definition: aged, definition_hash: "a" * 64)
    delete "#{base}/#{id}", headers: @admin
    assert_response :ok
  end

  test "update with an invalid definition is a 422 naming the condition path" do
    id = create!["segment"]["id"]
    patch "#{base}/#{id}",
          params: { definition: { version: 1, operator: "or", groups: [{ operator: "and", conditions: [{ type: "nope" }] }] } },
          headers: @admin, as: :json
    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["error"], "groups[0].conditions[0]"
  end

  test "update with a non-object definition is a 422" do
    id = create!["segment"]["id"]
    patch "#{base}/#{id}", params: { definition: "not-an-object" }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    assert_equal "definition must be an object", JSON.parse(response.body)["error"]
  end

  test "estimate with a segment_id from another project is 404" do
    other = Segment.create!(project: projects(:two), name: "theirs", definition: DEFINITION.deep_stringify_keys)
    Segments.stub(:available?, true) do
      post "#{base}/estimate", params: { segment_id: other.hashid }, headers: @member, as: :json
    end
    assert_response :not_found
  end

  test "a user with no role on the instance gets 403 on index" do
    foreign = doorkeeper_headers_for(users(:super_admin_user))
    get base, headers: foreign
    assert_response :forbidden
  end

  test "fields returns the builder catalogue for a member" do
    get "#{base}/fields", headers: @member
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal 1, body["version"]
    types = body["conditions"].map { |c| c["type"] }
    assert_equal Segments::Definition::TYPES.keys.sort, types.sort
  end

  test "fields is 403 for a user with no role on the instance" do
    foreign = doorkeeper_headers_for(users(:super_admin_user))
    get "#{base}/fields", headers: foreign
    assert_response :forbidden
  end

  test "estimate maps a too-heavy query to 422 query_too_heavy" do
    Segments.stub(:available?, true) do
      Segments::Runner.stub(:estimate, ->(**) { raise Analytics::QueryTooHeavy }) do
        post "#{base}/estimate", params: { definition: DEFINITION }, headers: @member, as: :json
      end
    end
    assert_response :unprocessable_entity
    assert_equal "query_too_heavy", JSON.parse(response.body)["error_code"]
  end

  test "delete archives, the list hides it, and PATCH archived false restores it" do
    id = create!["segment"]["id"]
    delete "#{base}/#{id}", headers: @admin
    assert_response :ok
    get base, headers: @admin
    assert_empty JSON.parse(response.body)["segments"]
    get "#{base}?archived=true", headers: @admin
    assert_equal 1, JSON.parse(response.body)["segments"].size
    patch "#{base}/#{id}", params: { archived: false }, headers: @admin, as: :json
    assert_response :ok
    assert_equal false, JSON.parse(response.body)["segment"]["archived"]
  end

  test "a segment from another project is 404" do
    other = Segment.create!(project: projects(:two), name: "theirs", definition: DEFINITION.deep_stringify_keys)
    get "#{base}/#{other.hashid}", headers: @admin
    assert_response :not_found
  end

  test "estimate accepts a draft definition" do
    Segments.stub(:available?, true) do
      Segments::Runner.stub(:estimate, { persons: 40, devices: 55, approximate: false, incomplete: false }) do
        post "#{base}/estimate", params: { definition: DEFINITION }, headers: @member, as: :json
      end
    end
    assert_response :ok
    assert_equal({ "persons" => 40, "devices" => 55, "approximate" => false, "incomplete" => false }, JSON.parse(response.body))
  end

  test "estimate refuses an archived segment" do
    id = create!["segment"]["id"]
    delete "#{base}/#{id}", headers: @admin
    Segments.stub(:available?, true) do
      post "#{base}/estimate", params: { segment_id: id }, headers: @member, as: :json
    end
    assert_response :not_found
  end

  test "estimate maps a stored definition that no longer parses to 422 invalid_definition" do
    id = create!["segment"]["id"]
    segment = Segment.find_by_hashid(id)
    invalid = DEFINITION.deep_stringify_keys
    invalid["groups"][0]["conditions"][0]["window"] = { "last_days" => 9999 }
    segment.update_columns(definition: invalid)
    Segments.stub(:available?, true) do
      post "#{base}/estimate", params: { segment_id: id }, headers: @member, as: :json
    end
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "invalid_definition", body["error_code"]
    assert_includes body["error"], "groups[0].conditions[0].window"
  end

  test "creating a purchase segment needs revenue collection enabled on the instance" do
    instances(:one).update!(revenue_collection_enabled: false)
    post base, params: { name: "Buyers", definition: PURCHASE_DEFINITION }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["error"], "revenue collection"

    instances(:one).update!(revenue_collection_enabled: true)
    post base, params: { name: "Buyers", definition: PURCHASE_DEFINITION }, headers: @admin, as: :json
    assert_response :created
  end

  test "estimate on a saved purchase segment is 422 invalid_definition once revenue collection is disabled" do
    id = create!(definition: PURCHASE_DEFINITION)["segment"]["id"]
    instances(:one).update!(revenue_collection_enabled: false)
    Segments.stub(:available?, true) do
      post "#{base}/estimate", params: { segment_id: id }, headers: @member, as: :json
    end
    assert_response :unprocessable_entity
    assert_equal "invalid_definition", JSON.parse(response.body)["error_code"]
  end

  test "estimate maps busy, expired window and unavailable ClickHouse" do
    Segments.stub(:available?, true) do
      Segments::Runner.stub(:estimate, ->(**) { raise Segments::Busy }) do
        post "#{base}/estimate", params: { definition: DEFINITION }, headers: @member, as: :json
        assert_response :too_many_requests
        assert_equal "segment_busy", JSON.parse(response.body)["error_code"]
      end
      Segments::Runner.stub(:estimate, ->(**) { raise Segments::WindowExpired }) do
        post "#{base}/estimate", params: { definition: DEFINITION }, headers: @member, as: :json
        assert_response :unprocessable_entity
        assert_equal "window_expired", JSON.parse(response.body)["error_code"]
      end
      Segments::Runner.stub(:estimate, ->(**) { raise Clickhouse::Unavailable, "segments" }) do
        post "#{base}/estimate", params: { definition: DEFINITION }, headers: @member, as: :json
        assert_response :service_unavailable
        assert_equal "clickhouse_unavailable", JSON.parse(response.body)["error_code"]
      end
    end
    Segments.stub(:available?, false) do
      post "#{base}/estimate", params: { definition: DEFINITION }, headers: @member, as: :json
      assert_response :service_unavailable
    end
  end

  test "count returns the exact size and a result id" do
    id = create!["segment"]["id"]
    manifest = Segments::Results::Manifest.new(result_id: "d" * 32, project_id: @project.id, persons: 7, devices: 9, rows: 9, incomplete: false)
    Segments::Results.stub(:for, manifest) do
      post "#{base}/#{id}/count", headers: @member, as: :json
    end
    assert_response :ok
    assert_equal({ "persons" => 7, "devices" => 9, "incomplete" => false, "result_id" => "d" * 32 }, JSON.parse(response.body))
  end

  test "breakdown returns buckets for the segment's result" do
    id = create!["segment"]["id"]
    payload = { by: "platform", total_persons: 3, buckets: [{ value: "ios", label: "ios", persons: 3 }] }
    Segments::Breakdown.stub(:call, ->(**) { payload }) do
      Segments.stub(:result_for, Segments::Results::Manifest.new(result_id: "b" * 32, project_id: @project.id,
                                                                  persons: 3, devices: 3, rows: 3, incomplete: false)) do
        post "#{base}/#{id}/breakdown", params: { by: "platform" }, headers: @member, as: :json
      end
    end
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "b" * 32, body["result_id"]
    assert_equal [{ "value" => "ios", "label" => "ios", "persons" => 3 }], body["buckets"]
  end

  test "breakdown with an unknown dimension is 422" do
    id = create!["segment"]["id"]
    manifest = Segments::Results::Manifest.new(result_id: "c" * 32, project_id: @project.id, persons: 1, devices: 1, rows: 1, incomplete: false)
    Segments.stub(:result_for, manifest) do
      post "#{base}/#{id}/breakdown", params: { by: "ip" }, headers: @member, as: :json
    end
    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["error"], "by must be one of"
  end

  test "breakdown with an expired result_id is 410" do
    id = create!["segment"]["id"]
    post "#{base}/#{id}/breakdown", params: { by: "platform", result_id: "a" * 32 }, headers: @member, as: :json
    assert_response :gone
    assert_equal "result_expired", JSON.parse(response.body)["error_code"]
  end

  test "users with an expired cursor is 410 and with a foreign result is 410" do
    id = create!["segment"]["id"]
    token = Segments::Members.encode_cursor("e" * 32, 10)
    post "#{base}/#{id}/users", params: { cursor: token }, headers: @member, as: :json
    assert_response :gone
    assert_equal "result_expired", JSON.parse(response.body)["error_code"]
  end

  test "users with a non-integer limit is 422, not 500" do
    id = create!["segment"]["id"]
    manifest = Segments::Results::Manifest.new(result_id: "f" * 32, project_id: @project.id, persons: 1, devices: 1, rows: 1, incomplete: false)
    Segments::Results.stub(:for, manifest) do
      post "#{base}/#{id}/users", params: { limit: [1, 2] }, headers: @member, as: :json
    end
    assert_response :unprocessable_entity
    assert_equal "limit must be an integer", JSON.parse(response.body)["error"]
  end

  test "count and users on an archived segment are 404" do
    id = create!["segment"]["id"]
    delete "#{base}/#{id}", headers: @admin
    post "#{base}/#{id}/count", headers: @member, as: :json
    assert_response :not_found
    post "#{base}/#{id}/users", headers: @member, as: :json
    assert_response :not_found
  end

  test "admin export enqueues the job, returns 202 and records an audit row" do
    entitle!(instances(:one))
    id = create!["segment"]["id"]
    segment = Segment.find_by_hashid(id)
    Sidekiq::Testing.fake! do
      SegmentExportJob.clear
      post "#{base}/#{id}/export", headers: @admin, as: :json
      assert_response :accepted
      assert_equal 1, SegmentExportJob.jobs.size
      export = SegmentExport.find(SegmentExportJob.jobs.last["args"][0])
      assert_equal segment.id, export.segment_id
      assert_equal "pending", JSON.parse(response.body)["export"]["status"]
      ev = AuditEvent.where(instance_id: @project.instance_id, action: "segment.exported").last
      assert_not_nil ev
      assert_equal export.hashid, ev.changes_data["after"]["export_id"]
    end
  end

  test "a member may export" do
    id = create!["segment"]["id"]
    post "#{base}/#{id}/export", headers: @member, as: :json
    assert_not_equal 403, response.status
  end

  test "export of an archived segment is 404" do
    id = create!["segment"]["id"]
    delete "#{base}/#{id}", headers: @admin
    post "#{base}/#{id}/export", headers: @admin, as: :json
    assert_response :not_found
  end

  test "export_status of another project's export is 404" do
    other_project = projects(:two)
    other_segment = Segment.create!(project: other_project, name: "theirs", definition: DEFINITION.deep_stringify_keys)
    other_export = SegmentExport.create!(project: other_project, segment: other_segment,
                                         definition: other_segment.definition, definition_hash: other_segment.definition_hash)
    get "#{API_PREFIX}/projects/#{@project.id}/segment_exports/#{other_export.hashid}", headers: @admin
    assert_response :not_found
  end

  test "download_url is nil while pending and present once ready with a file attached" do
    id = create!["segment"]["id"]
    segment = Segment.find_by_hashid(id)
    export = SegmentExport.create!(project: @project, segment: segment, definition: segment.definition, definition_hash: segment.definition_hash)
    get "#{API_PREFIX}/projects/#{@project.id}/segment_exports/#{export.hashid}", headers: @admin
    assert_response :ok
    assert_nil JSON.parse(response.body)["export"]["download_url"]

    export.file.attach(io: StringIO.new("person_key\n"), filename: "x.csv", content_type: "text/csv")
    export.update!(status: "ready", rows: 0)
    get "#{API_PREFIX}/projects/#{@project.id}/segment_exports/#{export.hashid}", headers: @admin
    assert_response :ok
    assert_not_nil JSON.parse(response.body)["export"]["download_url"]
  end

  test "exports lists an admin's exports for the project" do
    id = create!["segment"]["id"]
    segment = Segment.find_by_hashid(id)
    SegmentExport.create!(project: @project, segment: segment, definition: segment.definition, definition_hash: segment.definition_hash)
    get "#{API_PREFIX}/projects/#{@project.id}/segment_exports", headers: @admin
    assert_response :ok
    assert_equal 1, JSON.parse(response.body)["exports"].size
  end

  test "a member reads exports and export status" do
    id = create!["segment"]["id"]
    segment = Segment.find_by_hashid(id)
    export = SegmentExport.create!(project: @project, segment: segment, definition: segment.definition, definition_hash: segment.definition_hash)
    get "#{API_PREFIX}/projects/#{@project.id}/segment_exports", headers: @member
    assert_response :ok
    get "#{API_PREFIX}/projects/#{@project.id}/segment_exports/#{export.hashid}", headers: @member
    assert_response :ok
  end

  test "admin uploads an identifier list and has_identifier_list becomes true" do
    id = create!["segment"]["id"]
    segment = Segment.find_by_hashid(id)
    Segments::IdentifierList.stub(:replace!, lambda { |seg, identifiers|
      seg.update_columns(identifier_list_generation: "a" * 32)
      { generation: "a" * 32, count: identifiers.size }
    }) do
      post "#{base}/#{id}/identifier_list", params: { identifiers: ["a@x.io", "b@x.io"] }, headers: @admin, as: :json
    end
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal 2, body["count"]
    assert_equal true, body["segment"]["has_identifier_list"]
  end

  test "identifiers is a filtered parameter" do
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter({ "identifiers" => ["secret@x.io"] })
    assert_equal ActiveSupport::ParameterFilter::FILTERED, filtered["identifiers"]
  end

  test "admin uploads an identifier list as a CSV file" do
    id = create!["segment"]["id"]
    csv = Rack::Test::UploadedFile.new(StringIO.new("\uFEFFidentifier\r\nana@x.io\r\nb\u00F6b@x.io\r\n"), "text/csv", original_filename: "ids.csv")
    seen = nil
    capture = lambda do |_seg, ids|
      seen = ids
      { generation: "a" * 32, count: ids.size }
    end
    Segments::IdentifierList.stub(:replace!, capture) do
      post "#{base}/#{id}/identifier_list", params: { file: csv }, headers: @admin
    end
    assert_response :ok
    assert_equal ["ana@x.io", "b\u00F6b@x.io"], seen
    assert_equal [Encoding::UTF_8], seen.map(&:encoding).uniq

    bad = Rack::Test::UploadedFile.new(StringIO.new("\"unterminated\n"), "text/csv", original_filename: "ids.csv")
    post "#{base}/#{id}/identifier_list", params: { file: bad }, headers: @admin
    assert_response :unprocessable_entity
  end

  test "a member previews the identifier list with a search term" do
    id = create!["segment"]["id"]
    seen = nil
    preview = lambda do |_seg, q:|
      seen = q
      { identifiers: ["ana@x.io"], more: false }
    end
    Segments.stub(:available?, true) do
      Segments::IdentifierList.stub(:preview, preview) do
        get "#{base}/#{id}/identifier_list", params: { q: "ana" }, headers: @member
      end
    end
    assert_response :ok
    assert_equal({ "identifiers" => ["ana@x.io"], "more" => false }, JSON.parse(response.body))
    assert_equal "ana", seen
  end

  test "identifier list download is a CSV attachment, and 404 without a list" do
    entitle!(instances(:one))
    id = create!["segment"]["id"]
    Segments.stub(:available?, true) do
      get "#{base}/#{id}/identifier_list/download", headers: @member
      assert_response :not_found

      Segment.find_by_hashid(id).update_columns(identifier_list_generation: "c" * 32)
      Segments::IdentifierList.stub(:to_csv, "identifier\nana@x.io\n") do
        get "#{base}/#{id}/identifier_list/download", headers: @member
      end
    end
    assert_response :ok
    assert_equal "no-store", response.headers["Cache-Control"]
    ev = AuditEvent.where(instance_id: @project.instance_id, action: "segment.identifier_list_downloaded").last
    assert ev, "the download is audited"
    assert_equal "text/csv", response.media_type
    assert_match(/attachment; filename="segment_#{id}_identifiers\.csv"/, response.headers["Content-Disposition"])
    assert_equal "identifier\nana@x.io\n", response.body
  end

  test "identifier list preview of another project's segment is 404" do
    other = Segment.create!(project: projects(:two), name: "x", definition: DEFINITION.deep_stringify_keys)
    get "#{base}/#{other.hashid}/identifier_list", headers: @admin
    assert_response :not_found
  end

  test "a member may upload an identifier list" do
    id = create!["segment"]["id"]
    post "#{base}/#{id}/identifier_list", params: { identifiers: ["a@x.io"] }, headers: @member, as: :json
    assert_not_equal 403, response.status
  end

  test "identifier_list on an archived segment is 404" do
    id = create!["segment"]["id"]
    delete "#{base}/#{id}", headers: @admin
    post "#{base}/#{id}/identifier_list", params: { identifiers: ["a@x.io"] }, headers: @admin, as: :json
    assert_response :not_found
  end

  test "identifier_list returns 409 upload_in_progress when a previous upload holds the lock" do
    id = create!["segment"]["id"]
    Segments::IdentifierList.stub(:replace!, ->(*) { raise Segments::UploadInProgress }) do
      post "#{base}/#{id}/identifier_list", params: { identifiers: ["a@x.io"] }, headers: @admin, as: :json
    end
    assert_response :conflict
    assert_equal "upload_in_progress", JSON.parse(response.body)["error_code"]
  end

  test "identifier_list with a non-array identifiers is 422" do
    id = create!["segment"]["id"]
    Clickhouse.stub(:enabled?, true) do
      post "#{base}/#{id}/identifier_list", params: { identifiers: "nope" }, headers: @admin, as: :json
    end
    assert_response :unprocessable_entity
  end

  test "identifier_list records only the count in the audit row, never the identifiers" do
    entitle!(instances(:one))
    id = create!["segment"]["id"]
    segment = Segment.find_by_hashid(id)
    Segments::IdentifierList.stub(:replace!, lambda { |seg, identifiers|
      seg.update_columns(identifier_list_generation: "b" * 32)
      { generation: "b" * 32, count: identifiers.size }
    }) do
      post "#{base}/#{id}/identifier_list", params: { identifiers: ["secret@x.io"] }, headers: @admin, as: :json
    end
    assert_response :ok
    ev = AuditEvent.where(instance_id: @project.instance_id, action: "segment.identifier_list_replaced").last
    assert_not_nil ev
    assert_equal({ "count" => 1 }, ev.changes_data["after"])
    assert_not_includes ev.changes_data.to_s, "secret@x.io"
  end

  test "size_history returns newest-first rows for the current definition hash only" do
    id = create!["segment"]["id"]
    segment = Segment.find_by_hashid(id)
    SegmentSizeSnapshot.create!(segment: segment, date: 2.days.ago.to_date, definition_hash: segment.definition_hash,
                                persons: 5, devices: 6, incomplete: false)
    SegmentSizeSnapshot.create!(segment: segment, date: 1.day.ago.to_date, definition_hash: segment.definition_hash,
                                persons: 7, devices: 8, incomplete: true)
    SegmentSizeSnapshot.create!(segment: segment, date: Date.current, definition_hash: "stale" * 12,
                                persons: 99, devices: 99, incomplete: false)
    get "#{base}/#{id}/size_history", headers: @member
    assert_response :ok
    rows = JSON.parse(response.body)["size_history"]
    assert_equal [1.day.ago.to_date.to_s, 2.days.ago.to_date.to_s], rows.map { |r| r["date"] }
    assert_equal [7, 8, true], rows.first.values_at("persons", "devices", "incomplete")
  end

  test "size_history of another project's segment is 404" do
    other = Segment.create!(project: projects(:two), name: "theirs", definition: DEFINITION.deep_stringify_keys)
    get "#{base}/#{other.hashid}/size_history", headers: @admin
    assert_response :not_found
  end

  test "index and show include the latest size snapshot for the current hash" do
    id = create!["segment"]["id"]
    segment = Segment.find_by_hashid(id)
    SegmentSizeSnapshot.create!(segment: segment, date: Date.current, definition_hash: segment.definition_hash,
                                persons: 3, devices: 4, incomplete: false)
    get base, headers: @member
    assert_equal({ "date" => Date.current.to_s, "persons" => 3, "devices" => 4 },
                 JSON.parse(response.body)["segments"].first["size"])
    get "#{base}/#{id}", headers: @member
    assert_equal({ "date" => Date.current.to_s, "persons" => 3, "devices" => 4 }, JSON.parse(response.body)["segment"]["size"])
  end

  test "index returns at most LIST_LIMIT segments and says when it was cut" do
    3.times { |i| Segment.create!(project: @project, name: "Bound #{i}", definition: DEFINITION.deep_stringify_keys) }
    get base, headers: @admin
    assert_equal false, JSON.parse(response.body)["truncated"]

    limit = Api::V1::SegmentsController::LIST_LIMIT
    Api::V1::SegmentsController.send(:remove_const, :LIST_LIMIT)
    Api::V1::SegmentsController.const_set(:LIST_LIMIT, 2)
    get base, headers: @admin
    body = JSON.parse(response.body)
    assert_equal [2, true], [body["segments"].size, body["truncated"]]
  ensure
    Api::V1::SegmentsController.send(:remove_const, :LIST_LIMIT)
    Api::V1::SegmentsController.const_set(:LIST_LIMIT, limit)
  end

  test "users first page pins the result it is handed and refuses one from an older definition" do
    id = create!["segment"]["id"]
    segment = Segment.find_by_hashid(id)
    manifest = Segments::Results::Manifest.new(result_id: "f" * 32, project_id: @project.id, definition_hash: segment.definition_hash,
                                               persons: 1, devices: 1, rows: 1, incomplete: false)
    seen = []
    page = lambda { |manifest:, after:, limit:, q:|
      seen << [manifest.result_id, after, limit, q]
      { users: [], next_after: nil }
    }
    Segments::Results.stub(:fetch!, manifest) do
      Segments::Members.stub(:page, page) do
        post "#{base}/#{id}/users", params: { result_id: "f" * 32, q: "  alice " }, headers: @member, as: :json
      end
    end
    assert_response :ok
    assert_equal [["f" * 32, 0, 50, "  alice "]], seen
    stale = Segments::Results::Manifest.new(result_id: "f" * 32, project_id: @project.id, definition_hash: "older",
                                            persons: 1, devices: 1, rows: 1, incomplete: false)
    Segments::Results.stub(:fetch!, stale) do
      post "#{base}/#{id}/users", params: { result_id: "f" * 32 }, headers: @member, as: :json
    end
    assert_response :gone
  end

  test "a result built on an older identifier list, or on another segment's list, is refused" do
    id = create!["segment"]["id"]
    segment = Segment.find_by_hashid(id)
    segment.update_columns(identifier_list_generation: "c" * 32)
    pinned = lambda do |generation|
      manifest = Segments::Results::Manifest.new(result_id: "e" * 32, project_id: @project.id, definition_hash: segment.definition_hash,
                                                 list_generation: generation, persons: 1, devices: 1, rows: 1, incomplete: false)
      Segments::Results.stub(:fetch!, manifest) do
        Segments::Members.stub(:page, { users: [], next_after: nil }) do
          post "#{base}/#{id}/users", params: { result_id: "e" * 32 }, headers: @member, as: :json
          users = response.status
          post "#{base}/#{id}/breakdown", params: { by: "platform", result_id: "e" * 32 }, headers: @member, as: :json
          [users, response.status]
        end
      end
    end
    assert_equal [410, 410], pinned.call("b" * 32)
    assert_equal [410, 410], pinned.call(nil)
    assert_equal 200, pinned.call("c" * 32).first
  end

  test "users keeps the search term from the cursor even when the client drops q" do
    id = create!["segment"]["id"]
    segment = Segment.find_by_hashid(id)
    manifest = Segments::Results::Manifest.new(result_id: "g" * 32, project_id: @project.id, definition_hash: segment.definition_hash,
                                               persons: 1, devices: 1, rows: 1, incomplete: false)
    seen = []
    page = lambda { |manifest:, after:, limit:, q:|
      seen << [after, q, manifest.result_id[0], limit]
      { users: [], next_after: after.zero? ? 40 : nil }
    }
    Segments::Results.stub(:fetch!, manifest) do
      Segments::Members.stub(:page, page) do
        post "#{base}/#{id}/users", params: { result_id: "g" * 32, q: "bob" }, headers: @member, as: :json
        cursor = JSON.parse(response.body)["next_cursor"]
        post "#{base}/#{id}/users", params: { cursor: cursor }, headers: @member, as: :json
      end
    end
    assert_response :ok
    assert_equal [[0, "bob", "g", 50], [40, "bob", "g", 50]], seen
  end

  test "estimate of a draft edit borrows the segment's identifier list" do
    id = create!["segment"]["id"]
    segment = Segment.find_by_hashid(id)
    segment.update_columns(identifier_list_generation: "c" * 32)
    seen = nil
    est = lambda { |project:, definition:, list_generation: nil, segment_id: nil, lane: :dashboard|
      seen = [project.id, definition.class, list_generation, segment_id, lane]
      { persons: 1, devices: 1, approximate: false, incomplete: false }
    }
    Segments.stub(:available?, true) do
      Segments::Runner.stub(:estimate, est) do
        post "#{base}/estimate", params: { definition: DEFINITION, segment_id: id }, headers: @member, as: :json
      end
    end
    assert_response :ok
    assert_equal [@project.id, Segments::Definition, "c" * 32, segment.id, :dashboard], seen
  end

  test "estimate of a draft with an unknown or archived segment_id is 404, never a silent list-less estimate" do
    id = create!["segment"]["id"]
    Segments.stub(:available?, true) do
      post "#{base}/estimate", params: { definition: DEFINITION, segment_id: "nope" }, headers: @member, as: :json
      assert_response :not_found
      delete "#{base}/#{id}", headers: @admin
      post "#{base}/estimate", params: { definition: DEFINITION, segment_id: id }, headers: @member, as: :json
      assert_response :not_found
    end
  end
end
