namespace :grovs do
  namespace :custom_domain do
    # Break-glass for deployments whose egress cannot reach their own public ingress.
    desc "Force-activate a manual custom hostname without probing it"
    task :activate, [:hostname] => :environment do |_t, args|
      hostname = args[:hostname].to_s.strip.downcase
      abort "Usage: rake grovs:custom_domain:activate[links.example.com]" if hostname.blank?

      ch = CustomHostname.find_by(hostname: hostname)
      abort "No custom hostname found for #{hostname}" unless ch
      abort "#{hostname} is Cloudflare-provisioned; it activates from the Cloudflare poll" unless ch.manual?

      if ch.resolvable?
        puts "#{hostname} is already active."
        next
      end

      if CustomHostnameActivation.apply!(ch)
        puts "Activated #{hostname} (#{ch.purpose})."
        puts "Branding host set to #{hostname}." if ch.primary?
      else
        abort "Could not activate #{hostname} (status: #{ch.reload.status})"
      end
    end
  end
end
