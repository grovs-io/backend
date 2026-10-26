module EventStream
  module Adapters
    class S3
      # http_read_timeout bounds each read; this bounds the whole upload so it cannot outlive the delivery lock.
      TOTAL_TIMEOUT = 40

      def self.build_client(destination)
        settings = destination.settings
        # The Bookmark is the retry; SDK retries would stretch one request past the delivery lock.
        opts = { region: settings["region"], http_open_timeout: 10, http_read_timeout: 30, retry_limit: 0, max_attempts: 1 }
        if settings["endpoint"].present?
          uri = URI.parse(settings["endpoint"])
          unless Grovs.self_hosted? || (uri.is_a?(URI::HTTPS) && uri.host.present? && !HostGuard.blocked?(uri.host))
            raise ArgumentError, "S3 endpoint is not allowed"
          end

          opts[:endpoint] = settings["endpoint"]
        end
        opts[:force_path_style] = ActiveModel::Type::Boolean.new.cast(settings["force_path_style"]) if settings.key?("force_path_style")
        creds = destination.credentials_hash
        if creds["access_key_id"].present?
          opts[:credentials] = Aws::Credentials.new(creds["access_key_id"], creds["secret_access_key"])
        elsif !Grovs.self_hosted?
          # Only a self-hosted operator may lend the deployment's own AWS identity to a destination.
          raise ArgumentError, "S3 credentials are required"
        end
        client = Aws::S3::Client.new(**opts)
        if settings["endpoint"].present? && !Grovs.self_hosted?
          client.handlers.add(EventStream::PinnedS3Handler, step: :send)
        end
        client
      end

      def self.event_date(body)
        body[:occurred_at].to_s[0, 10].presence || Time.now.utc.strftime("%Y-%m-%d")
      end

      def self.object_key(project_hashid, prefix, date, first_body)
        base = "project=#{project_hashid}/date=#{date}/#{(Time.now.to_f * 1000).to_i}-#{first_body[:id].to_s[0, 12]}.ndjson.gz"
        prefix.present? ? "#{prefix.to_s.chomp('/')}/#{base}" : base
      end

      def initialize(destination)
        @destination = destination
      end

      # One object per event date so warehouse date filters never miss a late or cross-midnight event.
      def deliver(bodies)
        return [0, nil] if bodies.empty?

        client = (@client ||= self.class.build_client(@destination))
        bodies.group_by { |body| self.class.event_date(body) }.each do |date, group|
          Timeout.timeout(TOTAL_TIMEOUT) do
            client.put_object(
              bucket: @destination.settings["bucket"],
              key: self.class.object_key(@destination.project.hashid, @destination.settings["prefix"], date, group.first),
              body: gzip(group), content_type: "application/x-ndjson", content_encoding: "gzip"
            )
          end
        end
        [bodies.size, nil]
      rescue StandardError => e
        [0, "#{e.class}: #{e.message.truncate(200)}"]
      end

      private

      def gzip(bodies)
        io = StringIO.new
        Zlib::GzipWriter.wrap(io) { |w| bodies.each { |b| w.write(b.to_json, "\n") } }
        io.string
      end
    end
  end
end
