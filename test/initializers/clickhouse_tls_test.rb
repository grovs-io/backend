# frozen_string_literal: true

require 'test_helper'

class ClickhouseTlsTest < ActiveSupport::TestCase
  class FakeHttp
    attr_accessor :read_timeout, :write_timeout, :open_timeout, :use_ssl, :cert_store

    def request(_request)
      FakeResponse.new
    end
  end

  class FakeResponse
    def body = '{}'
    def code = '200'
    def to_hash = { 'content-type' => ['application/json'] }
  end

  def self_signed_ca
    key = OpenSSL::PKey::EC.generate('prime256v1')
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse('/CN=grovs test ca')
    cert.public_key = key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    ef = OpenSSL::X509::ExtensionFactory.new(cert, cert)
    cert.add_extension(ef.create_extension('basicConstraints', 'CA:TRUE', true))
    cert.sign(key, OpenSSL::Digest.new('SHA256'))
    cert
  end

  def spy_for(url)
    spy = FakeHttp.new
    Net::HTTP.stub(:new, spy) do
      Clickhouse.build_http_post_proc.call(url, {}, { 'query' => 'SELECT 1' })
    end
    spy
  end

  def with_ca(pem)
    previous = ENV['CLICKHOUSE_CA_CERT']
    ENV['CLICKHOUSE_CA_CERT'] = pem
    yield
  ensure
    previous ? ENV['CLICKHOUSE_CA_CERT'] = previous : ENV.delete('CLICKHOUSE_CA_CERT')
  end

  test 'https with CLICKHOUSE_CA_CERT trusts that CA and keeps peer verification' do
    ca = self_signed_ca
    with_ca(ca.to_pem) do
      spy = spy_for('https://10.60.1.10:8443/?database=grovs_test')
      assert spy.use_ssl
      assert_instance_of OpenSSL::X509::Store, spy.cert_store
      assert spy.cert_store.verify(ca), 'the private CA must verify against the installed store'
    end
  end

  test 'https without CLICKHOUSE_CA_CERT leaves the default system store' do
    with_ca(nil) do
      spy = spy_for('https://10.60.1.10:8443/')
      assert spy.use_ssl
      assert_nil spy.cert_store
    end
  end

  test 'plain http ignores CLICKHOUSE_CA_CERT' do
    with_ca(self_signed_ca.to_pem) do
      spy = spy_for('http://localhost:8123/')
      assert_not spy.use_ssl
      assert_nil spy.cert_store
    end
  end
end
