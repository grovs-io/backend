require "aws-sdk-s3"

# S3 side of the GeoIP cache (bin/ensure_geoip_db): S3-first fetch keeps MaxMind's quota alive.
class GeoipS3
  def initialize(client: Aws::S3::Client.new)
    @client = client
  end

  # Downloads the object and returns its age in whole days.
  def get(uri, dest)
    bucket, key = parse(uri)
    head = @client.head_object(bucket: bucket, key: key)
    @client.get_object(bucket: bucket, key: key, response_target: dest)
    ((Time.now - head.last_modified) / 86_400).floor
  end

  def put(uri, src)
    bucket, key = parse(uri)
    File.open(src, "rb") do |file|
      @client.put_object(bucket: bucket, key: key, body: file)
    end
  end

  private

  def parse(uri)
    raise ArgumentError, "not an s3:// uri: #{uri}" unless uri.to_s.start_with?("s3://")

    bucket, key = uri.delete_prefix("s3://").split("/", 2)
    raise ArgumentError, "missing bucket or key in #{uri}" if bucket.to_s.empty? || key.to_s.empty?

    [bucket, key]
  end
end

if __FILE__ == $PROGRAM_NAME
  command, uri, path = ARGV
  case command
  when "get" then puts GeoipS3.new.get(uri, path)
  when "put" then GeoipS3.new.put(uri, path)
  else abort "usage: geoip_s3.rb get|put s3://bucket/key local-path"
  end
end
