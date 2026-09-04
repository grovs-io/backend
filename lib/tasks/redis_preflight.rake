namespace :redis do
  desc "PING Redis using the deployment's exact TLS settings (run before deploying)"
  task preflight: :environment do
    url = ENV['REDIS_URL'].to_s
    params = Grovs::RedisSsl.params
    mode = params[:verify_mode] == OpenSSL::SSL::VERIFY_NONE ? "VERIFY_NONE" : "VERIFY_PEER"

    puts "url         : #{url.sub(%r{//[^@]*@}, '//***@')}"
    puts "tls         : #{url.start_with?('rediss://') ? 'on (rediss://)' : 'off — TLS settings are inert'}"
    puts "verify_mode : #{mode}#{params[:ca_file] ? " (ca_file=#{params[:ca_file]})" : ''}"

    begin
      puts "PING        : #{Redis.new(url: url, ssl_params: params).ping}"
      puts "OK — this image can reach Redis with these settings."
    rescue StandardError => e
      # Exception text can embed the URL (and its password) — redact before printing.
      safe = e.message.to_s.gsub(%r{//[^@\s]*@}, '//***@')
      safe = safe.gsub(url, '<REDIS_URL>') unless url.empty?
      abort "FAILED — #{e.class}: #{safe}\n" \
            "If this is a certificate error, supply REDIS_SSL_CA_FILE, or set " \
            "REDIS_SSL_VERIFY=none to restore the previous unverified behaviour."
    end
  end
end
