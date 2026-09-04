# frozen_string_literal: true

require 'test_helper'

# The timeout branch picks by SQL VERB, not body class — a Hash-bodied ALTER is still a write.
class ClickhouseTimeoutTest < ActiveSupport::TestCase
  class FakeHttp
    attr_accessor :read_timeout, :write_timeout, :open_timeout, :use_ssl

    def request(_request)
      FakeResponse.new
    end
  end

  class FakeResponse
    def body
      '{}'
    end

    def code
      '200'
    end

    def to_hash
      { 'content-type' => ['application/json'] }
    end
  end

  def spy_for(body)
    spy = FakeHttp.new
    response = nil
    Net::HTTP.stub(:new, spy) do
      response = Clickhouse.build_http_post_proc.call(
        'http://localhost:8123/?database=grovs_test',
        { 'X-Test' => '1' },
        body
      )
    end
    assert_instance_of ClickHouse::Client::Response, response
    spy
  end

  def read_timeout_for(body) = spy_for(body).read_timeout

  test 'SELECT read gets the 30s read ceiling' do
    assert_equal 30, read_timeout_for('query' => 'SELECT 1')
  end

  test 'WITH (CTE) read gets the 30s read ceiling' do
    assert_equal 30, read_timeout_for('query' => 'WITH x AS (SELECT 1) SELECT * FROM x')
  end

  test 'INSERT…SELECT write (execute-style Hash body) gets the 120s import window' do
    assert_equal 120, read_timeout_for('query' => 'INSERT INTO events SELECT * FROM events')
  end

  test 'ALTER DDL (execute-style Hash body) gets the 120s import window' do
    assert_equal 120, read_timeout_for('query' => 'ALTER TABLE events ADD COLUMN x String')
  end

  test 'String body (JSONEachRow insert) gets the 120s import window' do
    assert_equal 120, read_timeout_for('{"a":1}')
  end

  test 'the body write gets the same budget as the read, not Net::HTTP 60s default' do
    spy = spy_for('{"a":1}')

    assert_equal spy.read_timeout, spy.write_timeout
  end

  test 'env vars override both read and import timeouts' do
    with_env('CLICKHOUSE_HTTP_READ_TIMEOUT' => '7', 'CLICKHOUSE_HTTP_IMPORT_TIMEOUT' => '99') do
      assert_equal 7, read_timeout_for('query' => 'SELECT 1')
      assert_equal 99, read_timeout_for('query' => 'INSERT INTO events SELECT * FROM events')
    end
  end

  private

  def with_env(overrides)
    old = overrides.keys.index_with { |k| ENV[k] }
    overrides.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
