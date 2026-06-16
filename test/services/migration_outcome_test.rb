require "test_helper"

class MigrationOutcomeTest < ActiveSupport::TestCase
  fixtures :projects, :instances, :domains, :links, :redirect_configs

  setup do
    @link    = links(:basic_link)
    @project = projects(:one)
  end

  test "redirect outcome carries url, link, and provider" do
    o = MigrationOutcome.redirect(@link, provider: "branch")
    assert o.redirect?
    assert_not o.project_defaults?
    assert_equal @link, o.link
    assert_match %r{\Ahttps?://}, o.url
    assert_equal "branch", o.provider
  end

  test "redirect outcome appends query string to URL when provided" do
    o = MigrationOutcome.redirect(@link, query_string: "utm_source=email&promo=spring")
    assert_match(/\?utm_source=email&promo=spring\z/, o.url)
  end

  test "redirect outcome omits ? when query string is blank" do
    o = MigrationOutcome.redirect(@link, query_string: "")
    assert_not_includes o.url, "?"
  end

  test "project_defaults outcome carries project and provider, no link" do
    o = MigrationOutcome.project_defaults(@project, provider: "appsflyer")
    assert o.project_defaults?
    assert_not o.redirect?
    assert_equal @project, o.project
    assert_nil o.link
    assert_nil o.url
    assert_equal "appsflyer", o.provider
  end
end
