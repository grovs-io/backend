require "test_helper"

class UrlValidatorTest < ActiveSupport::TestCase
  # Lightweight model to test the validator in isolation
  class Validatable
    include ActiveModel::Model
    include ActiveModel::Validations
    attr_accessor :website

    validates :website, url: true
  end

  setup do
    @record = Validatable.new
  end

  # === Valid URLs ===

  test "accepts http URL" do
    @record.website = "http://example.com"
    assert @record.valid?
  end

  test "accepts https URL" do
    @record.website = "https://example.com"
    assert @record.valid?
  end

  test "accepts https URL with path" do
    @record.website = "https://example.com/path/to/page"
    assert @record.valid?
  end

  test "accepts https URL with query string" do
    @record.website = "https://example.com/search?q=test&page=1"
    assert @record.valid?
  end

  test "accepts https URL with port" do
    @record.website = "https://example.com:8080/path"
    assert @record.valid?
  end

  test "accepts https URL with fragment" do
    @record.website = "https://example.com/page#section"
    assert @record.valid?
  end

  test "accepts URL with subdomain" do
    @record.website = "https://www.example.com"
    assert @record.valid?
  end

  test "accepts URL with deep subdomain" do
    @record.website = "https://api.v2.example.com/endpoint"
    assert @record.valid?
  end

  test "accepts URL with encoded characters" do
    @record.website = "https://example.com/path%20with%20spaces"
    assert @record.valid?
  end

  # === Invalid URLs ===

  test "rejects ftp scheme" do
    @record.website = "ftp://example.com/file"
    assert_not @record.valid?
    assert_includes @record.errors[:website], "must be a valid URL"
  end

  test "rejects bare domain without scheme" do
    @record.website = "example.com"
    assert_not @record.valid?
  end

  test "rejects plain text" do
    @record.website = "not a url at all"
    assert_not @record.valid?
  end

  test "rejects empty string" do
    @record.website = ""
    assert_not @record.valid?
  end

  test "rejects nil" do
    @record.website = nil
    assert_not @record.valid?
  end

  test "rejects javascript scheme" do
    @record.website = "javascript:alert(1)"
    assert_not @record.valid?
  end

  test "rejects data URI" do
    @record.website = "data:text/html,<h1>test</h1>"
    assert_not @record.valid?
  end

  test "rejects mailto scheme" do
    @record.website = "mailto:test@example.com"
    assert_not @record.valid?
  end

  test "rejects URL with spaces in domain" do
    @record.website = "https://example .com"
    assert_not @record.valid?
  end

  test "accepts scheme-only without host per URI spec" do
    # Ruby's URI::DEFAULT_PARSER.make_regexp considers "https://" valid.
    # This is a known quirk of the RFC-based parser. The validator
    # delegates to the stdlib — this test documents that behavior.
    @record.website = "https://"
    assert @record.valid?
  end

  # === Error message ===

  test "error message says must be a valid URL" do
    @record.website = "invalid"
    @record.valid?
    assert_equal ["must be a valid URL"], @record.errors[:website]
  end

  test "valid URL produces no errors on website" do
    @record.website = "https://example.com"
    @record.valid?
    assert_empty @record.errors[:website]
  end
end
