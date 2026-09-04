require "test_helper"

class RefreshStoreMetadataJobTest < ActiveSupport::TestCase
  test "dispatches iOS to AppstoreService.refresh!" do
    called = nil
    AppstoreService.stub(:refresh!, ->(id) { called = id }) do
      RefreshStoreMetadataJob.new.perform(Grovs::Platforms::IOS, "com.test.app")
    end
    assert_equal "com.test.app", called
  end

  test "dispatches Android to GooglePlayService.refresh!" do
    called = nil
    GooglePlayService.stub(:refresh!, ->(id) { called = id }) do
      RefreshStoreMetadataJob.new.perform(Grovs::Platforms::ANDROID, "com.test.app")
    end
    assert_equal "com.test.app", called
  end
end
