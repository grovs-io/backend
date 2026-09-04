namespace :sso do
  desc "Turn SSO enforcement off for one instance. sso:disable_enforce[instance_id]"
  task :disable_enforce, [:instance_id] => :environment do |_t, args|
    conn = SsoConnection.find_by!(instance_id: Integer(args[:instance_id]))
    conn.update!(enforce: false)
    Audit.record(instance_id: conn.instance_id, action: "sso_connection.enforce_disabled",
                 actor: AuditActor.system("rake:sso:disable_enforce"), target: Audit.target_for(conn))
    puts "instance #{conn.instance_id}: enforce off"
  end
end
