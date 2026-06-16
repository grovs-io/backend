require "test_helper"

# Verifies the fail-closed guard with a bare controller, since every real
# controller authorizes and the defense-in-depth path never fires otherwise.
class DashboardAuthorizationTest < ActionController::TestCase
  class BareController < ActionController::API
    include DashboardAuthorization

    def naked
      render json: { ok: true }
    end

    def skipped
      skip_authorization
      render json: { ok: true }
    end

    def already_denied
      render json: { error: "no" }, status: :forbidden
    end

  end

  tests BareController

  setup do
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw do
      get "naked" => "dashboard_authorization_test/bare#naked"
      get "skipped" => "dashboard_authorization_test/bare#skipped"
      get "already_denied" => "dashboard_authorization_test/bare#already_denied"
    end
  end

  test "action that never authorizes is forced to 403" do
    get :naked
    assert_response :forbidden
  end

  test "skip_authorization lets the response through" do
    get :skipped
    assert_response :ok
    assert_equal true, JSON.parse(response.body)["ok"]
  end

  test "an action that already denied is not double-handled" do
    get :already_denied
    assert_response :forbidden
    assert_equal "no", JSON.parse(response.body)["error"]
  end

end
