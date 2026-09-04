# frozen_string_literal: true

require 'test_helper'
require_relative 'auth_test_helper'

class AnalyticsSessionsTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects

  setup do
    @admin_user = users(:admin_user)
    @project = projects(:one)
    @headers = doorkeeper_headers_for(@admin_user)
  end

  test 'returns 401 without auth' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/sessions", headers: api_headers
    end
    assert_response :unauthorized
  end

  test 'returns 403 for non-member project' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{projects(:two).id}/analytics/sessions", headers: @headers
    end
    assert_response :forbidden
  end

  test 'returns 503 when CH disabled' do
    Clickhouse.stub(:read_enabled?, false) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/sessions", headers: @headers
    end
    assert_response :service_unavailable
    assert_equal({ 'error' => 'Analytics temporarily unavailable' }, JSON.parse(response.body))
  end

  test 'index forwards params (incl. source) and passes result through' do
    captured = nil
    canary = { 'data' => [{ 'session_id' => 's1' }], 'next_cursor' => nil }
    fake = lambda { |*args, **kw| 
      captured = [args, kw]
      canary
    }
    Clickhouse.stub(:read_enabled?, true) do
      ::Analytics::SessionsQueryService.stub(:list, fake) do
        get "#{API_PREFIX}/projects/#{@project.id}/analytics/sessions",
            params: { start_date: '2026-04-01', end_date: '2026-05-01', limit: '25', source: 'campaigns' },
            headers: @headers
      end
    end
    assert_response :ok
    assert_equal canary, JSON.parse(response.body)
    assert_equal @project.id, captured[0][0]
    assert_equal Date.parse('2026-04-01'), captured[1][:start_date]
    assert_equal 25, captured[1][:limit]
    assert_equal 'campaigns', captured[1][:source], 'controller forwards source to the service'
  end

  test 'index returns 400 for an invalid source value' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/sessions",
          params: { source: 'totally_bogus' }, headers: @headers
    end
    assert_response :bad_request
    assert JSON.parse(response.body)['error'].include?('source')
  end

  test 'show returns 404 when service returns nil' do
    key = ::Analytics::SessionsQueryService.encode_key('sx', 5, '2026-05-01')
    Clickhouse.stub(:read_enabled?, true) do
      ::Analytics::SessionsQueryService.stub(:find, nil) do
        get "#{API_PREFIX}/projects/#{@project.id}/analytics/sessions/#{key}", headers: @headers
      end
    end
    assert_response :not_found
    assert_equal({ 'error' => 'Session not found' }, JSON.parse(response.body))
  end

  test 'show decodes the composite key and forwards session_id + visitor_id' do
    captured = nil
    fake = lambda { |*args, **kw| 
      captured = [args, kw]
      { session: { 'session_id' => 'sx' }, events: [] }
    }
    key = ::Analytics::SessionsQueryService.encode_key('sx', 5, '2026-05-01')
    Clickhouse.stub(:read_enabled?, true) do
      ::Analytics::SessionsQueryService.stub(:find, fake) do
        get "#{API_PREFIX}/projects/#{@project.id}/analytics/sessions/#{key}", headers: @headers
      end
    end
    assert_response :ok
    assert_equal @project.id, captured[0][0]
    assert_equal 'sx', captured[1][:session_id]
    assert_equal 5, captured[1][:visitor_id]
    assert_equal '2026-05-01', captured[1][:event_date]
  end

  test 'show returns 400 for a malformed (undecodable) id' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/sessions/not-a-valid-key", headers: @headers
    end
    assert_response :bad_request
    assert_equal({ 'error' => 'Invalid session id' }, JSON.parse(response.body))
  end

  # A well-formed base64 key carrying a bad date must 400 (not reach find → 500).
  test 'show returns 400 for a key with a non-parseable event_date' do
    forged = Base64.urlsafe_encode64({ s: 'x', v: 1, d: 'not-a-date' }.to_json, padding: false)
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/sessions/#{forged}", headers: @headers
    end
    assert_response :bad_request
    assert_equal({ 'error' => 'Invalid session id' }, JSON.parse(response.body))
  end

  # The key carries event_date, so a detail lookup can reach a cold session
  # directly, bypassing the range gate. event_date >730d fires for any plan.
  test 'show: rejects a session whose event_date is past the retention window' do
    key = ::Analytics::SessionsQueryService.encode_key('sess-cold', 999, (Date.current - 800).to_s)
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/sessions/#{key}", headers: @headers
    end
    assert_response :unprocessable_entity
    assert_equal 'retention_window_exceeded', JSON.parse(response.body)['error_code']
  end

  test 'show: a recent session is not a retention rejection' do
    key = ::Analytics::SessionsQueryService.encode_key('sess-hot', 999, (Date.current - 10).to_s)
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/sessions/#{key}", headers: @headers
    end
    assert_not_equal 'retention_window_exceeded', (JSON.parse(response.body)['error_code'] rescue nil)
  end
end
