require "test_helper"

# Master flag — must default false so SaaS/private deployments are unaffected.
class SelfHostedFlagTest < ActiveSupport::TestCase
  teardown { ENV.delete("GROVS_SELF_HOSTED") }

  test "defaults to false when env is unset (SaaS/private behavior)" do
    ENV.delete("GROVS_SELF_HOSTED")
    assert_not Grovs.self_hosted?
  end

  test "is true only when explicitly set to the string 'true'" do
    ENV["GROVS_SELF_HOSTED"] = "true"
    assert Grovs.self_hosted?
  end

  test "any other value is treated as not self-hosted" do
    ["false", "1", "TRUE", "yes", ""].each do |val|
      ENV["GROVS_SELF_HOSTED"] = val
      assert_not Grovs.self_hosted?, "#{val.inspect} must NOT enable self-hosted mode"
    end
  end
end
