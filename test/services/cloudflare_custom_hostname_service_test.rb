require "test_helper"

class CloudflareCnameTargetTest < ActiveSupport::TestCase
  teardown { disable_custom_domains! }

  test "cname_target is the configured Cloudflare target in Cloudflare mode" do
    enable_custom_domains!
    assert_equal "proxy.sqd.link", CloudflareCustomHostnameService.cname_target
  end

  # The proxy.sqd.link default would otherwise tell a self-hosted operator to point DNS at Grovs SaaS.
  test "cname_target is nil in manual mode" do
    enable_manual_custom_domains!
    assert_nil CloudflareCustomHostnameService.cname_target
  end
end

class CloudflareCustomHostnameServiceTest < ActiveSupport::TestCase
  setup { enable_custom_domains! }
  teardown { disable_custom_domains! }

  def fake(success, body)
    Struct.new(:success?, :parsed_response).new(success, body)
  end

  test "create parses cf id, status, and ssl_status" do
    body = { "result" => { "id" => "cf_abc", "status" => "pending",
                           "ssl" => { "status" => "pending_validation" } }, "success" => true }
    HTTParty.stub(:post, fake(true, body)) do
      r = CloudflareCustomHostnameService.create(hostname: "links.acme.com")
      assert r[:success]
      assert_equal "cf_abc", r[:cf_id]
      assert_equal "pending", r[:status]
      assert_equal "pending_validation", r[:ssl_status]
    end
  end

  test "create sends ssl method 'txt' and type 'dv' by default" do
    body = { "result" => { "id" => "cf_txt", "status" => "pending",
                           "ssl" => { "status" => "pending_validation", "method" => "txt" } }, "success" => true }
    sent_body = nil
    capture = lambda do |_url, opts|
      sent_body = opts[:body]
      fake(true, body)
    end
    HTTParty.stub(:post, capture) do
      CloudflareCustomHostnameService.create(hostname: "links.acme.com")
    end
    parsed = JSON.parse(sent_body)
    assert_equal "links.acme.com", parsed["hostname"]
    assert_equal "txt", parsed.dig("ssl", "method")
    assert_equal "dv", parsed.dig("ssl", "type")
  end

  test "create honours an explicit ssl_method override (http for legacy paths)" do
    body = { "result" => { "id" => "cf_http", "status" => "pending",
                           "ssl" => { "status" => "pending_validation", "method" => "http" } }, "success" => true }
    sent_body = nil
    capture = lambda do |_url, opts|
      sent_body = opts[:body]
      fake(true, body)
    end
    HTTParty.stub(:post, capture) do
      CloudflareCustomHostnameService.create(hostname: "links.acme.com", ssl_method: "http")
    end
    assert_equal "http", JSON.parse(sent_body).dig("ssl", "method")
  end

  test "parse extracts ssl_method and TXT validation record from a TXT-method response" do
    body = {
      "success" => true,
      "result" => {
        "id" => "cf_txt",
        "status" => "pending",
        "ssl" => {
          "status" => "pending_validation",
          "method" => "txt",
          "type" => "dv",
          "validation_records" => [
            { "status" => "pending",
              "txt_name" => "_acme-challenge.branch.tabkeep.uk",
              "txt_value" => "9BsoPkc-xyz" }
          ]
        }
      }
    }
    HTTParty.stub(:post, fake(true, body)) do
      r = CloudflareCustomHostnameService.create(hostname: "branch.tabkeep.uk")
      assert_equal "txt", r[:ssl_method]
      assert_equal [{ "name" => "_acme-challenge.branch.tabkeep.uk", "value" => "9BsoPkc-xyz" }],
                   r[:txt_records]
    end
  end

  test "parse drops 'valid' (already-satisfied) records and keeps the pending one" do
    # DCV rotation: CF emits a stale "valid" + new "pending". The "valid" record was
    # already added by the customer and doesn't need to be re-rendered.
    body = {
      "success" => true,
      "result" => {
        "id" => "cf_txt",
        "status" => "pending",
        "ssl" => {
          "status" => "pending_validation", "method" => "txt",
          "validation_records" => [
            { "status" => "valid",   "txt_name" => "_stale.x", "txt_value" => "OLD" },
            { "status" => "pending", "txt_name" => "_acme.x",  "txt_value" => "NEW" }
          ]
        }
      }
    }
    HTTParty.stub(:post, fake(true, body)) do
      r = CloudflareCustomHostnameService.create(hostname: "first.example.com")
      assert_equal [{ "name" => "_acme.x", "value" => "NEW" }], r[:txt_records],
                   "stale valid record must be filtered; only the pending one reaches the FE"
    end
  end

  test "parse returns empty txt_records when every record is already validated" do
    # All "valid" means the customer's DNS already satisfies every challenge CF asked
    # for. There's nothing left to do — the FE should render nothing, NOT a stale
    # "add this record" instruction for a record CF has already validated.
    body = {
      "success" => true,
      "result" => {
        "id" => "cf_all_valid",
        "status" => "pending",
        "ssl" => {
          "status" => "pending_validation", "method" => "txt",
          "validation_records" => [
            { "status" => "valid", "txt_name" => "_a.x", "txt_value" => "A" },
            { "status" => "valid", "txt_name" => "_b.x", "txt_value" => "B" }
          ]
        }
      }
    }
    HTTParty.stub(:post, fake(true, body)) do
      r = CloudflareCustomHostnameService.create(hostname: "first.example.com")
      assert_equal [], r[:txt_records],
                   "fully validated records yield an empty array — nothing for the customer to do"
    end
  end

  test "parse returns empty txt_records when CF emits no validation_records (e.g. after activation)" do
    body = { "success" => true, "result" => {
      "id" => "cf_active", "status" => "active",
      "ssl" => { "status" => "active", "method" => "txt" }
    } }
    HTTParty.stub(:get, fake(true, body)) do
      r = CloudflareCustomHostnameService.status(cf_id: "cf_active")
      assert_equal "txt", r[:ssl_method]
      assert_equal [], r[:txt_records],
                   "activated hostnames carry no validation records; empty array, not nil"
    end
  end

  test "status surfaces SSL validation errors" do
    body = { "result" => { "id" => "cf_abc", "status" => "pending",
                           "ssl" => { "status" => "pending_validation",
                                      "validation_errors" => [{ "message" => "no CNAME found" }] } } }
    HTTParty.stub(:get, fake(true, body)) do
      r = CloudflareCustomHostnameService.status(cf_id: "cf_abc")
      assert_match "no CNAME found", r[:verification_errors]
    end
  end

  test "create treats a Cloudflare body of success:false as failure (HTTP 200)" do
    body = { "success" => false, "errors" => [{ "message" => "rate limited" }] }
    HTTParty.stub(:post, fake(true, body)) do
      r = CloudflareCustomHostnameService.create(hostname: "links.acme.com")
      assert_not r[:success]
      assert_match "rate limited", r[:verification_errors].to_s
    end
  end

  test "create returns success:false and does not raise on a transport error" do
    HTTParty.stub(:post, ->(*) { raise SocketError, "boom" }) do
      r = CloudflareCustomHostnameService.create(hostname: "links.acme.com")
      assert_not r[:success]
    end
  end

  test "delete returns true on success" do
    HTTParty.stub(:delete, fake(true, {})) do
      assert CloudflareCustomHostnameService.delete(cf_id: "cf_abc")
    end
  end

  test "delete treats an already-gone hostname (404 code) as success" do
    HTTParty.stub(:delete, fake(false, { "errors" => [{ "code" => 1436 }] })) do
      assert CloudflareCustomHostnameService.delete(cf_id: "cf_abc")
    end
  end

  test "delete returns false on a real failure (so the caller retries)" do
    HTTParty.stub(:delete, fake(false, { "errors" => [{ "code" => 1000 }] })) do
      assert_not CloudflareCustomHostnameService.delete(cf_id: "cf_abc")
    end
  end

  test "delete returns false on HTTP 200 with body success:false (not really deleted)" do
    HTTParty.stub(:delete, fake(true, { "success" => false, "errors" => [{ "code" => 1000 }] })) do
      assert_not CloudflareCustomHostnameService.delete(cf_id: "cf_abc")
    end
  end

  test "delete returns true for a blank cf id" do
    assert CloudflareCustomHostnameService.delete(cf_id: nil)
  end

  test "cname_target reads the env var" do
    assert_equal "proxy.sqd.link", CloudflareCustomHostnameService.cname_target
  end

  test "lookup returns the existing hostname's cf id (for adopting a crashed-create orphan)" do
    body = { "result" => [{ "id" => "cf_found", "status" => "pending",
                            "ssl" => { "status" => "pending_validation" } }], "success" => true }
    HTTParty.stub(:get, fake(true, body)) do
      r = CloudflareCustomHostnameService.lookup(hostname: "links.acme.com")
      assert r[:success]
      assert_equal "cf_found", r[:cf_id]
      assert_equal "pending_validation", r[:ssl_status]
    end
  end

  test "lookup returns success:false when no hostname matches" do
    HTTParty.stub(:get, fake(true, { "result" => [], "success" => true })) do
      r = CloudflareCustomHostnameService.lookup(hostname: "links.acme.com")
      assert_not r[:success]
      assert_nil r[:cf_id]
    end
  end

  test "lookup returns success:false and does not raise on a transport error" do
    HTTParty.stub(:get, ->(*) { raise SocketError, "boom" }) do
      r = CloudflareCustomHostnameService.lookup(hostname: "links.acme.com")
      assert_not r[:success]
    end
  end

  # ── Hostname Pre-Validation (`result.ownership_verification`) ───────────────
  # CF emits a SECOND TXT challenge alongside the `_acme-challenge` SSL one when
  # the zone has Hostname Pre-Validation enabled. It lives at
  # result.ownership_verification (parallel to result.ssl). Missing this field
  # is why a customer on the tabkeep.uk zone waits forever for SSL with only the
  # _acme-challenge TXT in place — CF holds issuance until both records resolve.

  test "parse extracts ownership_verification TXT (Hostname Pre-Validation)" do
    body = {
      "success" => true,
      "result" => {
        "id" => "cf_ov",
        "status" => "pending",
        "ssl" => { "status" => "pending_validation", "method" => "txt",
                   "validation_records" => [
                     { "status" => "pending", "txt_name" => "_acme-challenge.x", "txt_value" => "ssl-v" }
                   ] },
        "ownership_verification" => {
          "type" => "txt",
          "name" => "_cf-custom-hostname.branch.tabkeep.uk",
          "value" => "a890192a-e150-4ee0-8f3a-4e14035ceb8b"
        }
      }
    }
    HTTParty.stub(:post, fake(true, body)) do
      r = CloudflareCustomHostnameService.create(hostname: "branch.tabkeep.uk")
      assert_equal [{ "name" => "_acme-challenge.x", "value" => "ssl-v" }], r[:txt_records]
      assert_equal "_cf-custom-hostname.branch.tabkeep.uk",   r[:ov_txt_name]
      assert_equal "a890192a-e150-4ee0-8f3a-4e14035ceb8b",    r[:ov_txt_value]
    end
  end

  test "parse returns nil ownership_verification fields when CF omits the block (zone without pre-validation)" do
    body = {
      "success" => true,
      "result" => {
        "id" => "cf_no_ov",
        "status" => "pending",
        "ssl" => { "status" => "pending_validation", "method" => "txt",
                   "validation_records" => [
                     { "status" => "pending", "txt_name" => "_a.x", "txt_value" => "v" }
                   ] }
        # no ownership_verification key
      }
    }
    HTTParty.stub(:post, fake(true, body)) do
      r = CloudflareCustomHostnameService.create(hostname: "no-pre-val.example")
      assert_nil r[:ov_txt_name]
      assert_nil r[:ov_txt_value]
    end
  end

  # ── Multi-CA dual issuance: txt_records as a multi-entry array ──────────────
  # CF issues certs from multiple CAs in parallel. Each emits its own ACME challenge,
  # arriving as separate entries under `ssl.validation_records` with the same TXT
  # name but different values. All must be in DNS for both certs to issue. The
  # parser must surface ALL of them, not just one.

  test "parse returns ALL pending validation records as an array (multi-CA dual issuance)" do
    body = {
      "success" => true,
      "result" => {
        "id" => "cf_multi",
        "status" => "pending",
        "ssl" => { "status" => "pending_validation", "method" => "txt",
                   "validation_records" => [
                     { "status" => "pending", "txt_name" => "_acme-challenge.x", "txt_value" => "CA1" },
                     { "status" => "pending", "txt_name" => "_acme-challenge.x", "txt_value" => "CA2" }
                   ] }
      }
    }
    HTTParty.stub(:post, fake(true, body)) do
      r = CloudflareCustomHostnameService.create(hostname: "x")
      assert_equal 2, r[:txt_records].size,
                   "multi-CA dual issuance: both records must reach the customer"
      assert_equal %w[CA1 CA2], r[:txt_records].map { |rec| rec["value"] }
      assert_equal %w[_acme-challenge.x _acme-challenge.x], r[:txt_records].map { |rec| rec["name"] }
    end
  end

  test "parse drops status=valid (stale, already-satisfied) records from the array" do
    # During DCV rotation CF returns one stale "valid" and one new "pending". The
    # customer doesn't need to act on "valid" — it's already in DNS and being honored.
    body = {
      "success" => true,
      "result" => {
        "id" => "cf_rot",
        "status" => "pending",
        "ssl" => { "status" => "pending_validation", "method" => "txt",
                   "validation_records" => [
                     { "status" => "valid",   "txt_name" => "_acme-challenge.x", "txt_value" => "STALE" },
                     { "status" => "pending", "txt_name" => "_acme-challenge.x", "txt_value" => "NEW"   }
                   ] }
      }
    }
    HTTParty.stub(:post, fake(true, body)) do
      r = CloudflareCustomHostnameService.create(hostname: "x")
      assert_equal 1, r[:txt_records].size,
                   "valid (stale) records must be filtered — the customer already added them"
      assert_equal "NEW", r[:txt_records].first["value"]
    end
  end

  test "parse surfaces records with unknown status — defensive against new CF statuses" do
    # CF can introduce new statuses (e.g. "queued", "issued"). Hiding any non-"pending"
    # entry would silently swallow records the customer might need to act on.
    body = {
      "success" => true,
      "result" => {
        "id" => "cf_unknown",
        "status" => "pending",
        "ssl" => { "status" => "pending_validation", "method" => "txt",
                   "validation_records" => [
                     { "status" => "queued", "txt_name" => "_acme-challenge.x", "txt_value" => "abc" }
                   ] }
      }
    }
    HTTParty.stub(:post, fake(true, body)) do
      r = CloudflareCustomHostnameService.create(hostname: "x")
      assert_equal 1, r[:txt_records].size, "unknown CF statuses must surface, not be hidden"
      assert_equal "abc", r[:txt_records].first["value"]
    end
  end

  test "parse returns empty txt_records when CF emits no validation_records" do
    body = { "success" => true, "result" => {
      "id" => "cf_active", "status" => "active",
      "ssl" => { "status" => "active", "method" => "txt" }
    } }
    HTTParty.stub(:get, fake(true, body)) do
      r = CloudflareCustomHostnameService.status(cf_id: "cf_active")
      assert_equal [], r[:txt_records]
    end
  end

  test "parse ignores non-TXT ownership_verification methods (future-proofing)" do
    # CF could conceivably add email/file verification methods carrying the same
    # shape. The dashboard renders TXT records only, so non-TXT must NOT poison
    # the row's ownership_verification_txt_* columns.
    body = {
      "success" => true,
      "result" => {
        "id" => "cf_email",
        "status" => "pending",
        "ssl" => { "status" => "pending_validation", "method" => "txt",
                   "validation_records" => [
                     { "status" => "pending", "txt_name" => "_a.x", "txt_value" => "v" }
                   ] },
        "ownership_verification" => {
          "type" => "email", "name" => "admin@example.com", "value" => "click-link"
        }
      }
    }
    HTTParty.stub(:post, fake(true, body)) do
      r = CloudflareCustomHostnameService.create(hostname: "email-method.example")
      assert_nil r[:ov_txt_name], "non-TXT ownership_verification must not be persisted as TXT"
      assert_nil r[:ov_txt_value]
    end
  end
end
