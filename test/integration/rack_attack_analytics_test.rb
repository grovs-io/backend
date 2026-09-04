# frozen_string_literal: true

require 'test_helper'

# Tests the analytics rate-limiting discriminator logic.
#
# Rack::Attack throttles are gated behind `Rails.env.production?`, so they
# are not registered in the test environment. Instead of stubbing the env,
# we test the matching regex and conditions directly — the same conditions
# the throttle block evaluates.
class RackAttackAnalyticsTest < ActiveSupport::TestCase
  ANALYTICS_PATH_REGEX = %r{/api/v1/projects/\w+/analytics/}

  # ── Path matching ──────────────────────────────────────────────────

  test 'regex matches analytics overview path' do
    assert_match ANALYTICS_PATH_REGEX, '/api/v1/projects/abc123/analytics/overview/kpis'
  end

  test 'regex matches analytics events path' do
    assert_match ANALYTICS_PATH_REGEX, '/api/v1/projects/abc123/analytics/events'
  end

  test 'regex matches analytics sessions path' do
    assert_match ANALYTICS_PATH_REGEX, '/api/v1/projects/abc123/analytics/sessions'
  end

  test 'regex matches analytics retention path' do
    assert_match ANALYTICS_PATH_REGEX, '/api/v1/projects/abc123/analytics/retention/summary'
  end

  test 'regex matches analytics events volume path' do
    assert_match ANALYTICS_PATH_REGEX, '/api/v1/projects/abc123/analytics/events/volume'
  end

  test 'regex does NOT match non-analytics project paths' do
    assert_no_match ANALYTICS_PATH_REGEX, '/api/v1/projects/abc123/links'
    assert_no_match ANALYTICS_PATH_REGEX, '/api/v1/projects/abc123/campaigns'
    assert_no_match ANALYTICS_PATH_REGEX, '/api/v1/projects/abc123/visitors'
  end

  test 'regex does NOT match admin paths' do
    assert_no_match ANALYTICS_PATH_REGEX, '/api/v1/admin/instances'
  end

  test 'regex does NOT match oauth path' do
    assert_no_match ANALYTICS_PATH_REGEX, '/oauth/token'
  end

  test 'regex matches hashid-style project IDs' do
    assert_match ANALYTICS_PATH_REGEX, '/api/v1/projects/xYz123AbC/analytics/overview/kpis'
  end

  # ── Discriminator logic (simulating the throttle block) ────────────

  test 'discriminator: returns IP for GET analytics on API subdomain' do
    request = build_request(method: 'GET', host: api_host, path: analytics_path, ip: '1.2.3.4')
    assert_equal '1.2.3.4', evaluate_discriminator(request)
  end

  test 'discriminator: returns nil for POST requests (not GET)' do
    request = build_request(method: 'POST', host: api_host, path: analytics_path, ip: '1.2.3.4')
    assert_nil evaluate_discriminator(request)
  end

  test 'discriminator: returns nil for non-analytics paths' do
    request = build_request(method: 'GET', host: api_host, path: '/api/v1/projects/abc/links', ip: '1.2.3.4')
    assert_nil evaluate_discriminator(request)
  end

  test 'discriminator: returns nil for SDK subdomain' do
    request = build_request(method: 'GET', host: sdk_host, path: analytics_path, ip: '1.2.3.4')
    assert_nil evaluate_discriminator(request)
  end

  test 'discriminator: returns nil for go subdomain' do
    request = build_request(method: 'GET', host: go_host, path: analytics_path, ip: '1.2.3.4')
    assert_nil evaluate_discriminator(request)
  end

  # ── Throttle config verification ───────────────────────────────────

  test 'analytics throttle config: present in rack_attack initializer source' do
    source = File.read(Rails.root.join('config/initializers/rack_attack.rb'))
    assert_includes source, "'analytics/ip'"
    assert_includes source, 'limit: 200'
    assert_includes source, 'period: 1.minute'
  end

  private

  def api_host
    "#{Grovs::Subdomains::API}.sqd.link"
  end

  def sdk_host
    "#{Grovs::Subdomains::SDK}.sqd.link"
  end

  def go_host
    "go.sqd.link"
  end

  def analytics_path
    '/api/v1/projects/abc123/analytics/overview/kpis'
  end

  # Replicate the exact discriminator logic from rack_attack.rb
  def evaluate_discriminator(request)
    if request.host&.start_with?(Grovs::Subdomains::API) &&
       request.get? &&
       request.path.match?(ANALYTICS_PATH_REGEX)
      request.ip
    end
  end

  def build_request(method:, host:, path:, ip:)
    env = Rack::MockRequest.env_for("http://#{host}#{path}", method: method)
    env['REMOTE_ADDR'] = ip
    Rack::Attack::Request.new(env)
  end
end
