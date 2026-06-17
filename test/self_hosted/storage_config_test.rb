require "test_helper"

# storage.yml emits the S3-compatible endpoint keys only when S3_ENDPOINT is set;
# unset → identical to the previous AWS-only config.
class SelfHostedStorageConfigTest < ActiveSupport::TestCase
  teardown do
    ENV.delete("S3_ENDPOINT")
    ENV.delete("S3_FORCE_PATH_STYLE")
  end

  # Render storage.yml exactly as Rails' config loader does (plain ERB, no trim mode).
  def render_amazon
    erb = ERB.new(File.read(Rails.root.join("config/storage.yml"))).result
    YAML.load(erb)["amazon"]
  end

  test "no S3_ENDPOINT => amazon config is the original AWS-only shape" do
    ENV.delete("S3_ENDPOINT")
    a = render_amazon
    assert_equal %w[service access_key_id secret_access_key region bucket], a.keys,
                 "AWS deployments must get the identical 5-key config as before"
    assert_not a.key?("endpoint")
    assert_not a.key?("force_path_style")
  end

  test "S3_ENDPOINT set => endpoint and force_path_style are emitted" do
    ENV["S3_ENDPOINT"] = "http://object-storage:9000"
    a = render_amazon
    assert_equal "http://object-storage:9000", a["endpoint"]
    assert_equal true, a["force_path_style"], "defaults to true for path-style S3-compatible stores"
  end

  test "S3_FORCE_PATH_STYLE can be overridden to false" do
    ENV["S3_ENDPOINT"] = "http://object-storage:9000"
    ENV["S3_FORCE_PATH_STYLE"] = "false"
    a = render_amazon
    assert_equal false, a["force_path_style"]
  end
end
