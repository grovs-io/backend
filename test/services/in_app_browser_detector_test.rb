require "test_helper"

class InAppBrowserDetectorTest < ActiveSupport::TestCase
  CORPUS = YAML.load_file(Rails.root.join("test/fixtures/files/in_app_browser_user_agents.yml"))

  CORPUS["positive"].each do |name, ua|
    test("matches #{name}") { assert InAppBrowserDetector.match?(ua), ua }
  end

  CORPUS["negative"].each do |name, ua|
    test("does not match #{name}") { assert_not InAppBrowserDetector.match?(ua), ua }
  end

  test "nil and blank are not in-app browsers" do
    assert_not InAppBrowserDetector.match?(nil)
    assert_not InAppBrowserDetector.match?("")
  end
end
