require "test_helper"

class RpushStreamCapTest < ActiveSupport::TestCase
  setup { RpushStreamCap.install! }

  def streams_for(remote)
    client = Struct.new(:remote_settings).new({ settings_max_concurrent_streams: remote })
    Rpush::Daemon::Apnsp8::Delivery.new(nil, client, nil, nil).send(:remote_max_concurrent_streams)
  end

  test "never opens more streams than http-2 allows locally" do
    assert_equal 100, streams_for(1000)
  end

  test "keeps a lower server limit" do
    assert_equal 1, streams_for(1)
  end

  test "keeps rpush's fallback when the server sent no limit" do
    assert_equal 100, streams_for(0x7fffffff)
  end
end
