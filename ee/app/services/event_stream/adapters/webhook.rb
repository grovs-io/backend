module EventStream
  module Adapters
    class Webhook
      OPEN_TIMEOUT = 10
      READ_TIMEOUT = 30
      TOTAL_TIMEOUT = 40
      ERROR_SNIPPET_BYTES = 200

      def self.signature(secret, timestamp, body)
        OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, "#{timestamp}.#{body}")
      end

      # Secret and headers are read once here, on the caller's thread: delivery threads share this adapter.
      def initialize(destination, deadline: nil)
        @destination = destination
        @deadline = deadline
        @secret = destination.signing_secret
        @custom_headers = destination.credentials_hash["headers"] || {}
      end

      # Returns [accepted_prefix_count, error]; past the deadline it stops early with no error.
      def deliver(bodies)
        address = target_address
        return [0, "url resolves to a private address"] if address == :blocked

        accepted = 0
        bodies.each_slice(@destination.batch_size) do |chunk|
          break if accepted.positive? && @deadline && Time.current >= @deadline

          error = post(chunk, address)
          return [accepted, error] if error

          accepted += chunk.size
        end
        [accepted, nil]
      end

      private

      # Resolved once per adapter; nil means self-hosted, where normal resolution is trusted.
      def target_address
        return @target_address if defined?(@target_address)

        @target_address = HostGuard.vetted_address(URI.parse(@destination.url.to_s).host)
      rescue HostGuard::Blocked, URI::InvalidURIError
        @target_address = :blocked
      end

      # The tenant's response is streamed, never buffered; Timeout bounds a slow trickle that read_timeout cannot.
      def post(chunk, address)
        body = chunk.map(&:to_json).join("\n")
        snippet = +""
        resp = Timeout.timeout(TOTAL_TIMEOUT) do
          HTTParty.post(@destination.url, headers: headers(body), body: body, follow_redirects: false, stream_body: true,
                                          open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT,
                                          connection_adapter: PinnedConnection, connection_adapter_options: { ipaddr: address }) do |fragment|
            snippet << fragment.to_s.byteslice(0, ERROR_SNIPPET_BYTES - snippet.bytesize) if snippet.bytesize < ERROR_SNIPPET_BYTES
          end
        end
        return nil if resp.code.to_i.between?(200, 299)

        # The remote body goes to the log, not to last_error: the API shows that to any project member.
        Rails.logger.warn(message: "event_stream_webhook_rejected", destination_id: @destination.id, code: resp.code, body: snippet.scrub)
        "HTTP #{resp.code}"
      rescue StandardError => e
        "#{e.class}: #{e.message.truncate(200)}"
      end

      def headers(body)
        timestamp = Time.now.to_i.to_s
        @custom_headers.merge(
          "Content-Type" => "application/x-ndjson",
          "User-Agent" => "Grovs-EventStream/1",
          "X-Grovs-Destination" => @destination.hashid,
          "X-Grovs-Batch" => SecureRandom.uuid,
          "X-Grovs-Signature" => "t=#{timestamp},v1=#{self.class.signature(@secret, timestamp, body)}"
        )
      end
    end
  end
end
