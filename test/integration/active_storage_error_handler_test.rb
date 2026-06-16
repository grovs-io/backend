require "test_helper"
require Rails.root.join("app/middleware/active_storage_error_handler")

class ActiveStorageErrorHandlerTest < ActiveSupport::TestCase
  test "passes through successful app response" do
    app = ->(_env) { [200, { "Content-Type" => "text/plain" }, ["ok"]] }
    status, headers, body = ActiveStorageErrorHandler.new(app).call(
      Rack::MockRequest.env_for("/rails/active_storage/blobs/123")
    )

    assert_equal 200, status
    assert_equal "text/plain", headers["Content-Type"]
    assert_equal ["ok"], body
  end

  test "returns json not found response for missing active storage json request" do
    app = ->(_env) { raise ActiveRecord::RecordNotFound, "missing blob" }
    env = Rack::MockRequest.env_for(
      "/rails/active_storage/blobs/redirect/missing/file.png",
      "HTTP_ACCEPT" => "application/json"
    )

    status, headers, body = ActiveStorageErrorHandler.new(app).call(env)

    assert_equal 404, status
    assert_equal "application/json", headers["Content-Type"]
    assert_equal(
      { "error" => "The requested file could not be found or has been deleted" },
      JSON.parse(body.join)
    )
  end

  test "returns html not found response for missing active storage html request" do
    app = ->(_env) { raise ActiveRecord::RecordNotFound, "missing blob" }
    env = Rack::MockRequest.env_for(
      "/rails/active_storage/blobs/redirect/missing/file.png",
      "HTTP_ACCEPT" => "text/html"
    )

    status, headers, body = ActiveStorageErrorHandler.new(app).call(env)

    assert_equal 404, status
    assert_equal "text/html", headers["Content-Type"]
    assert_includes body.join, "File Not Found"
  end

  test "re-raises record not found outside active storage paths" do
    app = ->(_env) { raise ActiveRecord::RecordNotFound, "missing record" }
    env = Rack::MockRequest.env_for("/api/v1/projects/missing")

    assert_raises(ActiveRecord::RecordNotFound) do
      ActiveStorageErrorHandler.new(app).call(env)
    end
  end
end
