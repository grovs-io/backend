require "socket"
require "openssl"
require "http/2"

# HTTP/2 APNs/FCM stand-in; the handler answers each request with one of the actions in #answer.
class FakeApnsServer
  Request = Struct.new(:connection, :index, :path, :headers, :body, keyword_init: true) do
    def device_token = path.delete_prefix("/3/device/")
  end

  attr_reader :requests, :connections

  def initialize(tls: true, &handler)
    @tls = tls
    @handler = handler || ->(_request) { :ok }
    @requests = []
    @connections = 0
    @sockets = []
    @lock = Mutex.new
    @tcp = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { accept_loop }
  end

  def url = "#{@tls ? 'https' : 'http'}://127.0.0.1:#{@tcp.addr[1]}"

  def handler=(handler)
    @lock.synchronize { @handler = handler }
  end

  # Kills every open connection with a RST, as a NAT or load balancer dropping state would look on the next write.
  def reset_all
    @lock.synchronize { @sockets.each { |tcp| rst(tcp) }.clear }
  end

  def stop
    reset_all
    @thread.kill
    @tcp.close
  end

  private

  def accept_loop
    loop do
      tcp = @tcp.accept
      number = @lock.synchronize do
        @sockets << tcp
        @connections += 1
      end
      Thread.new { serve(tcp, number) }
    end
  end

  def serve(tcp, number)
    io = @tls ? OpenSSL::SSL::SSLSocket.new(tcp, self.class.ssl_context).tap(&:accept) : tcp
    conn = HTTP2::Server.new
    conn.on(:frame) { |bytes| io.write(bytes) unless tcp.closed? }
    count = 0
    conn.on(:stream) do |stream|
      headers = {}
      body = +""
      stream.on(:headers) { |h| headers.merge!(h.to_h) }
      stream.on(:data) { |d| body << d }
      stream.on(:half_close) do
        request = Request.new(connection: number, index: count += 1, path: headers[":path"], headers: headers, body: body)
        @lock.synchronize { @requests << request }
        answer(stream, @lock.synchronize { @handler }.call(request), tcp)
      end
    end
    loop { conn << io.readpartial(16_384) }
  rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
    nil
  ensure
    @lock.synchronize { @sockets.delete(tcp) }
  end

  def answer(stream, action, tcp)
    case action
    when :ok then stream.headers({ ":status" => "200", "apns-id" => SecureRandom.uuid }, end_stream: true)
    when :ok_then_reset
      stream.headers({ ":status" => "200" }, end_stream: true)
      Thread.new do
        sleep 0.05
        rst(tcp)
      end
    when :headers_then_reset
      stream.headers({ ":status" => "410" })
      rst(tcp)
    when :reset then rst(tcp)
    when :hang then nil
    when Array
      code, reason = action
      stream.headers({ ":status" => code.to_s, "content-type" => "application/json" })
      stream.data({ reason: reason }.to_json)
    else raise ArgumentError, "unknown action #{action.inspect}"
    end
  end

  def rst(tcp)
    return if tcp.closed?

    tcp.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
    tcp.close
  rescue IOError, SystemCallError
    nil
  end

  def self.ssl_context
    @ssl_context ||= begin
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=127.0.0.1")
      cert.public_key = key.public_key
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + 86_400
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
      OpenSSL::SSL::SSLContext.new.tap do |ctx|
        ctx.cert = cert
        ctx.key = key
        ctx.alpn_select_cb = ->(protocols) { "h2" if protocols.include?("h2") }
      end
    end
  end
end
