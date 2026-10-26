require "test_helper"

class SegmentExportMailerTest < ActionMailer::TestCase
  fixtures :instances, :projects, :users

  DEFINITION = { "version" => 1, "operator" => "or", "groups" => [{ "operator" => "and", "conditions" => [
    { "type" => "event", "any" => true, "window" => { "last_days" => 30 } }
  ] }] }.freeze

  setup do
    @segment = Segment.create!(project: projects(:one), name: "Buyers <VIP>", definition: DEFINITION)
    @export = SegmentExport.create!(project: @segment.project, segment: @segment, user: users(:admin_user), rows: 7,
                                    definition: @segment.definition, definition_hash: @segment.definition_hash)
  end

  test "the ready mail is branded html with a text fallback, both pointing at the segment's Exports panel" do
    mail = SegmentExportMailer.ready(@export)

    assert_equal [users(:admin_user).email], mail.to
    assert_equal %w[text/plain text/html], mail.parts.map(&:mime_type)
    html = mail.html_part.body.to_s
    assert_includes html, Grovs::Assets::LOGO_LARGE
    assert_includes html, "Buyers &lt;VIP&gt;"
    assert_includes html, "7 users"
    env = projects(:one).test? ? "Test" : "Production"
    url = "#{ENV.fetch("REACT_HOST_PROTOCOL", "https://")}#{ENV.fetch("REACT_HOST")}/segments/#{@segment.hashid}?instance_id=#{projects(:one).instance_id}&amp;env_type=#{env}"
    assert_includes html, url
    text = mail.text_part.body.to_s
    assert_includes text, 'Audience → Segments → "Buyers <VIP>"'
    assert_includes text, "(7 users)"
  end
end
