require "test_helper"
require "tempfile"

class GrovsRedisSslTest < ActiveSupport::TestCase
  def with_env(vars)
    old = vars.keys.index_with { |k| ENV[k] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  test "verifies the peer by default" do
    with_env("REDIS_SSL_VERIFY" => nil, "REDIS_SSL_CA_FILE" => nil) do
      assert_equal({ verify_mode: OpenSSL::SSL::VERIFY_PEER }, Grovs::RedisSsl.params)
    end
  end

  test "supplies a private CA bundle when configured" do
    Tempfile.create("ca") do |ca|
      with_env("REDIS_SSL_VERIFY" => nil, "REDIS_SSL_CA_FILE" => "  #{ca.path}  ") do
        assert_equal(
          { verify_mode: OpenSSL::SSL::VERIFY_PEER, ca_file: ca.path },
          Grovs::RedisSsl.params,
          "the path must be stripped before use"
        )
      end
    end
  end

  test "a blank CA path falls back to the system trust store" do
    with_env("REDIS_SSL_VERIFY" => nil, "REDIS_SSL_CA_FILE" => "   ") do
      assert_equal({ verify_mode: OpenSSL::SSL::VERIFY_PEER }, Grovs::RedisSsl.params)
    end
  end

  test "an unreadable CA path fails loudly instead of silently not verifying" do
    with_env("REDIS_SSL_VERIFY" => nil, "REDIS_SSL_CA_FILE" => "/nope/missing-ca.pem") do
      error = assert_raises(ArgumentError) { Grovs::RedisSsl.params }
      assert_match(/REDIS_SSL_CA_FILE/, error.message)
    end
  end

  test "verification off short-circuits the CA check" do
    with_env("REDIS_SSL_VERIFY" => "none", "REDIS_SSL_CA_FILE" => "/nope/missing-ca.pem") do
      assert_equal({ verify_mode: OpenSSL::SSL::VERIFY_NONE }, Grovs::RedisSsl.params)
    end
  end

  test "opts out of verification case-insensitively" do
    ["none", "NONE", " None "].each do |value|
      with_env("REDIS_SSL_VERIFY" => value, "REDIS_SSL_CA_FILE" => nil) do
        assert_equal({ verify_mode: OpenSSL::SSL::VERIFY_NONE }, Grovs::RedisSsl.params,
                     "REDIS_SSL_VERIFY=#{value.inspect} must disable verification")
      end
    end
  end

  test "any other value keeps verification on" do
    with_env("REDIS_SSL_VERIFY" => "false", "REDIS_SSL_CA_FILE" => nil) do
      assert_equal({ verify_mode: OpenSSL::SSL::VERIFY_PEER }, Grovs::RedisSsl.params)
    end
  end
end
