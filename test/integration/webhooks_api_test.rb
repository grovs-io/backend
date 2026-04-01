require "test_helper"
require_relative "auth_test_helper"

class WebhooksApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances

  WEBHOOK_KEY = "test-quotas-webhook-key"

  # --- stripe_webhook ---

  test "stripe_webhook with signature verification failure returns 400" do
    Stripe::Webhook.stub(:construct_event, ->(_p, _s, _e) { raise Stripe::SignatureVerificationError.new("bad sig", "sig") }) do
      post "#{API_PREFIX}/webhooks/stripe",
        params: { type: "invoice.paid" }.to_json,
        headers: api_headers.merge(
          "Content-Type" => "application/json",
          "HTTP_STRIPE_SIGNATURE" => "bad_signature"
        )
      assert_response :bad_request
      json = JSON.parse(response.body)
      assert_equal "Failed", json["error"]
    end
  end

  test "stripe_webhook passes sig_header from HTTP_STRIPE_SIGNATURE to construct_event" do
    received_sig = nil
    stub = lambda { |_payload, sig, _secret|
      received_sig = sig
      raise Stripe::SignatureVerificationError.new("test", "sig")
    }

    Stripe::Webhook.stub(:construct_event, stub) do
      post "#{API_PREFIX}/webhooks/stripe",
        params: { type: "test" }.to_json,
        headers: api_headers.merge(
          "Content-Type" => "application/json",
          "HTTP_STRIPE_SIGNATURE" => "sig_value_abc"
        )
    end
    assert_equal "sig_value_abc", received_sig
  end

  test "stripe_webhook with valid signature calls handle_webhook and returns 200" do
    fake_event = Stripe::Event.construct_from({ id: "evt_test", type: "invoice.paid" })
    payload = { id: "evt_test", type: "invoice.paid" }.to_json
    webhook_handled = false

    Stripe::Webhook.stub(:construct_event, ->(_p, _s, _e) { fake_event }) do
      StripeService.stub(:handle_webhook, ->(_event) { webhook_handled = true }) do
        post "#{API_PREFIX}/webhooks/stripe",
          params: payload,
          headers: api_headers.merge(
            "Content-Type" => "application/json",
            "HTTP_STRIPE_SIGNATURE" => "valid_sig"
          )
        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal "Ok", json["message"]
      end
    end
    assert webhook_handled, "StripeService.handle_webhook should have been called"
  end

  test "stripe_webhook when handle_webhook raises returns 500" do
    fake_event = Stripe::Event.construct_from({ id: "evt_err", type: "invoice.paid" })

    Stripe::Webhook.stub(:construct_event, ->(_p, _s, _e) { fake_event }) do
      StripeService.stub(:handle_webhook, ->(_event) { raise StandardError, "boom" }) do
        post "#{API_PREFIX}/webhooks/stripe",
          params: { id: "evt_err", type: "invoice.paid" }.to_json,
          headers: api_headers.merge(
            "Content-Type" => "application/json",
            "HTTP_STRIPE_SIGNATURE" => "valid_sig"
          )
        assert_response :internal_server_error
      end
    end
  end

  test "stripe_webhook lock contention returns 200" do
    fake_event = Stripe::Event.construct_from({ id: "evt_locked", type: "invoice.paid" })

    Stripe::Webhook.stub(:construct_event, ->(_p, _s, _e) { fake_event }) do
      StripeService.stub(:handle_webhook, ->(_event) { raise StripeService::WebhookLockContention, "locked" }) do
        post "#{API_PREFIX}/webhooks/stripe",
          params: { id: "evt_locked", type: "invoice.paid" }.to_json,
          headers: api_headers.merge(
            "Content-Type" => "application/json",
            "HTTP_STRIPE_SIGNATURE" => "valid_sig"
          )
        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal "Ok", json["message"]
      end
    end
  end

  test "stripe_webhook with malformed JSON returns 400" do
    Stripe::Webhook.stub(:construct_event, ->(_p, _s, _e) { raise JSON::ParserError, "bad json" }) do
      post "#{API_PREFIX}/webhooks/stripe",
        params: "not json{{{",
        headers: api_headers.merge(
          "Content-Type" => "application/json",
          "HTTP_STRIPE_SIGNATURE" => "some_sig"
        )
      assert_response :bad_request
      json = JSON.parse(response.body)
      assert_equal "Failed to parse", json["error"]
    end
  end

  # --- send_stripe_quotas ---

  test "send_stripe_quotas without API key returns 403" do
    with_webhook_key(WEBHOOK_KEY) do
      post "#{API_PREFIX}/webhooks/send_stripe_quotas",
        headers: api_headers
      assert_response :forbidden
      json = JSON.parse(response.body)
      assert_equal "Forbidden", json["error"]
    end
  end

  test "send_stripe_quotas with wrong API key returns 403" do
    with_webhook_key(WEBHOOK_KEY) do
      post "#{API_PREFIX}/webhooks/send_stripe_quotas",
        headers: api_headers.merge("X-API-KEY" => "wrong-key")
      assert_response :forbidden
    end
  end

  test "send_stripe_quotas with valid API key calls set_usage and returns 200" do
    usage_calls = []
    with_webhook_key(WEBHOOK_KEY) do
      StripeService.stub(:set_usage, ->(instance) { usage_calls << instance.id }) do
        post "#{API_PREFIX}/webhooks/send_stripe_quotas",
          headers: api_headers.merge("X-API-KEY" => WEBHOOK_KEY)
        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal "Ok", json["message"]
      end
    end
    assert usage_calls.any?, "StripeService.set_usage should have been called for at least one instance"
  end

  private

  def with_webhook_key(key)
    original = ENV["SENT_QUOTAS_WEBHOOK_KEY"]
    ENV["SENT_QUOTAS_WEBHOOK_KEY"] = key
    yield
  ensure
    ENV["SENT_QUOTAS_WEBHOOK_KEY"] = original
  end
end
