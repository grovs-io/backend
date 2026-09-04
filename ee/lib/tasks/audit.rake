namespace :audit do
  desc "Verify the audit hash chain. audit:verify[instance_id] for one instance, no arg for all."
  task :verify, [:instance_id] => :environment do |_t, args|
    ids = args[:instance_id].present? ? [Integer(args[:instance_id])] : AuditChainHead.pluck(:instance_id)
    broken = false
    ids.each do |id|
      result = AuditEvent.verify_chain(id)
      if result[:ok]
        puts "instance #{id}: OK #{result[:count]} events"
      else
        broken = true
        puts "instance #{id}: BROKEN at sequence #{result[:sequence]}: #{result[:reason]}"
      end
    end
    exit 1 if broken
  end
end
