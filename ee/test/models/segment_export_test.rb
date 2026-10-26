require "test_helper"

class SegmentExportTest < ActiveSupport::TestCase
  DEFINITION = { "version" => 1, "operator" => "or", "groups" => [{ "operator" => "and", "conditions" => [
    { "type" => "event", "event_name" => "checkout", "window" => { "last_days" => 30 } }
  ] }] }.freeze

  test "destroying a project with a segment export purges the file and does not violate the segment foreign key" do
    instance = Instance.create!(uri_scheme: "expfk#{SecureRandom.hex(4)}", api_key: "key-#{SecureRandom.hex(4)}")
    project = Project.create!(name: "FK Test", identifier: "fk-test-#{SecureRandom.hex(4)}", instance: instance)
    segment = Segment.create!(project: project, name: "Buyers", definition: DEFINITION)
    export = SegmentExport.create!(project: project, segment: segment, definition: segment.definition, definition_hash: segment.definition_hash)
    export.file.attach(io: StringIO.new("person_key\n"), filename: "x.csv", content_type: "text/csv")
    attachment_id = export.file.attachment.id

    assert project.destroy!
    assert_nil ActiveStorage::Attachment.find_by(id: attachment_id)
  end
end
