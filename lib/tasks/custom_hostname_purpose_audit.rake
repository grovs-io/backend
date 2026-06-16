namespace :custom_hostnames do
  desc "Pre-deploy audit: prints any CustomHostname row that will be flipped to purpose=migration."
  task audit_purpose_backfill: :environment do
    conflicts = ActiveRecord::Base.connection.exec_query(<<~SQL)
      SELECT ms.id AS source_id, ms.project_id, ms.old_host
      FROM migration_sources ms
      JOIN custom_hostnames ch
        ON ch.hostname = ms.old_host AND ch.project_id = ms.project_id
    SQL

    if conflicts.empty?
      puts "OK — no CustomHostname rows shared with a MigrationSource. Data migration will be a no-op."
      return
    end

    puts "AUDIT — #{conflicts.count} row(s) will be flipped to purpose='migration':"
    conflicts.each { |r| puts "  project_id=#{r['project_id']} hostname=#{r['old_host']}" }
    puts ""
    abort(
      "Each affected project will lose its 'primary' custom hostname; short links will " \
      "render on the sqd.link host until a new 'primary' is added. Confirm with the " \
      "product/customer-success owner before deploying."
    )
  end
end
