require "test_helper"

class EventStreamMailerTest < ActionMailer::TestCase
  fixtures :instances, :users, :instance_roles, :projects

  setup do
    @destination = EventDestination.create!(project: projects(:one), name: "Warehouse <prod>", kind: "webhook",
                                            settings: { "url" => "https://h.example.com" })
    @destination.update_columns(last_error: "HTTP 500")
    env = projects(:one).test? ? "Test" : "Production"
    @url = "#{ENV.fetch("REACT_HOST_PROTOCOL", "https://")}#{ENV.fetch("REACT_HOST")}/settings/developers/event_stream?instance_id=#{projects(:one).instance_id}&amp;env_type=#{env}"
  end

  test "paused is branded html with a text fallback, naming the destination, the error and the settings page" do
    mail = EventStreamMailer.paused(@destination)

    assert_includes mail.bcc, users(:admin_user).email
    assert_equal %w[text/plain text/html], mail.parts.map(&:mime_type)
    html = mail.html_part.body.to_s
    assert_includes html, Grovs::Assets::LOGO_LARGE
    assert_includes html, "Warehouse &lt;prod&gt;"
    assert_includes html, "HTTP 500"
    assert_includes html, @url
    assert_includes mail.text_part.body.to_s, "Last error: HTTP 500"
  end

  test "gap is branded html with a text fallback, naming the skipped range and the settings page" do
    from = Time.utc(2026, 10, 1, 8)
    to = Time.utc(2026, 10, 3, 9)
    mail = EventStreamMailer.gap(@destination, from: from, to: to)

    assert_equal %w[text/plain text/html], mail.parts.map(&:mime_type)
    html = mail.html_part.body.to_s
    assert_includes html, Grovs::Assets::LOGO_LARGE
    assert_includes html, "2026-10-01 08:00 UTC"
    assert_includes html, "2026-10-03 09:00 UTC"
    assert_includes html, @url
    assert_includes mail.text_part.body.to_s, from.iso8601
  end
end
