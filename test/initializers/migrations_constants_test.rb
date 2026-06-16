require "test_helper"

class MigrationsConstantsTest < ActiveSupport::TestCase
  test "MVP_PROVIDERS contains only the two shipping providers" do
    assert_equal %w[branch appsflyer], Grovs::Migrations::MVP_PROVIDERS
  end

  test "MVP_PROVIDERS is frozen" do
    assert Grovs::Migrations::MVP_PROVIDERS.frozen?
  end

  test "provider constants have stable string values used in DB enums" do
    assert_equal "branch",    Grovs::Migrations::PROVIDER_BRANCH
    assert_equal "appsflyer", Grovs::Migrations::PROVIDER_APPSFLYER
  end

  test "GENERATED_FROM_PLATFORM is the literal string 'migration'" do
    assert_equal "migration", Grovs::Migrations::GENERATED_FROM_PLATFORM
  end

  # Adjust + Singular constants were intentionally removed (see app_constants.rb comment).
  # This is a guardrail to flag if someone re-adds them without also wiring the dispatcher,
  # validator, and DB CHECK constraint.
  test "PROVIDER_ADJUST and PROVIDER_SINGULAR constants are NOT defined" do
    assert_not Grovs::Migrations.const_defined?(:PROVIDER_ADJUST),
      "PROVIDER_ADJUST defined without dispatcher + CHECK constraint wiring"
    assert_not Grovs::Migrations.const_defined?(:PROVIDER_SINGULAR),
      "PROVIDER_SINGULAR defined without dispatcher + CHECK constraint wiring"
    assert_not Grovs::Migrations.const_defined?(:ALL_PROVIDERS),
      "ALL_PROVIDERS removed in favor of MVP_PROVIDERS — re-introducing it requires re-wiring everything"
  end
end
