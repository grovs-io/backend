namespace :smoke_links do
  # One-time cleanup for the smoke-test project: the API soft-deletes links
  # (active=false), so years of automated smoke runs accumulated ~160k dead
  # links that every links search still scans. This hard-deletes them and
  # their children, in batches, oldest data only.
  #
  # Usage:
  #   DOMAIN_ID=<id> bundle exec rake smoke_links:purge              # dry run
  #   DOMAIN_ID=<id> CONFIRM=yes bundle exec rake smoke_links:purge  # delete
  #   Optional: BATCH_SIZE=1000 OLDER_THAN_DAYS=2 SLEEP=0.1
  desc "Hard-delete soft-deleted smoke links (and children) for a domain"
  task purge: :environment do
    domain_id = ENV.fetch("DOMAIN_ID").to_i
    batch_size = (ENV["BATCH_SIZE"] || 1_000).to_i
    older_than = (ENV["OLDER_THAN_DAYS"] || 2).to_i.days.ago
    sleep_between = (ENV["SLEEP"] || 0.1).to_f
    confirmed = ENV["CONFIRM"] == "yes"

    scope = Link.where(domain_id: domain_id, active: false)
                .where("updated_at < ?", older_than)
                .where("name ILIKE :t OR title ILIKE :t OR path ILIKE :t", t: "%smoke%")

    total = scope.count
    puts "Domain #{domain_id}: #{total} soft-deleted smoke links older than #{older_than}"

    unless confirmed
      puts "DRY RUN — set CONFIRM=yes to delete. Sample:"
      scope.limit(5).each { |l| puts "  id=#{l.id} path=#{l.path} name=#{l.name} updated_at=#{l.updated_at}" }
      next
    end

    # NOTE: links.redirect_config_id points at the PROJECT-level RedirectConfig
    # shared by every link in the project — it must never be deleted here.
    deleted = 0
    skipped = 0
    last_id = 0
    loop do
      # Ordered id-cursor: protected rows are skipped, never re-fetched, and
      # can't cause an early stop.
      ids = scope.where("links.id > ?", last_id).order(:id).limit(batch_size).pluck(:id)
      break if ids.empty?
      last_id = ids.max

      # Never destroy revenue data: links referenced by purchases/subscriptions
      # are excluded (FK on purchase_events would block the delete anyway).
      protected_ids = PurchaseEvent.where(link_id: ids).distinct.pluck(:link_id) |
                      SubscriptionState.where(link_id: ids).distinct.pluck(:link_id)
      skipped += protected_ids.size
      ids -= protected_ids
      next if ids.empty?

      ActiveRecord::Base.transaction do
        VisitorLastVisit.where(link_id: ids).delete_all
        CustomRedirect.where(link_id: ids).delete_all
        LinkDailyStatistic.where(link_id: ids).delete_all
        Event.where(link_id: ids).delete_all
        Action.where(link_id: ids).delete_all
        Link.where(id: ids).delete_all
      end

      deleted += ids.size
      puts "#{Time.current.utc.iso8601} deleted #{deleted}/#{total}#{" (skipped #{skipped} with purchase data)" if skipped.positive?}"
      sleep sleep_between
    end

    puts "Done. Hard-deleted #{deleted} links."
  end
end
