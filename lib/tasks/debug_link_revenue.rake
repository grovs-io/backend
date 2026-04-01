namespace :debug do
  desc "Show link_daily_statistics revenue breakdown for a project"
  task link_revenue: :environment do
    project_id = ENV["PROJECT_ID"]
    abort "Usage: PROJECT_ID=123 rails debug:link_revenue" unless project_id

    puts "\n=== link_daily_statistics with non-zero revenue ==="
    rows = ActiveRecord::Base.connection.exec_query(<<~SQL)
      SELECT lds.id, lds.link_id, lds.event_date, lds.platform, lds.revenue,
             l.path AS link_path
      FROM link_daily_statistics lds
      JOIN links l ON l.id = lds.link_id
      WHERE lds.project_id = #{ActiveRecord::Base.connection.quote(project_id.to_i)}
        AND lds.revenue != 0
      ORDER BY lds.event_date DESC, lds.link_id
    SQL

    rows.each do |r|
      puts "  lds.id=#{r['id']} link=#{r['link_path']} date=#{r['event_date']} platform=#{r['platform']} revenue=#{r['revenue']}"
    end
    puts "  (none)" if rows.empty?

    puts "\n=== purchase_events with link_id set ==="
    events = ActiveRecord::Base.connection.exec_query(<<~SQL)
      SELECT pe.id, pe.event_type, pe.product_id, pe.usd_price_cents, pe.price_cents,
             pe.currency, pe.link_id, pe.device_id, pe.processed, pe.store,
             pe.webhook_validated, pe.store_source, pe.date,
             l.path AS link_path
      FROM purchase_events pe
      LEFT JOIN links l ON l.id = pe.link_id
      WHERE pe.project_id = #{ActiveRecord::Base.connection.quote(project_id.to_i)}
        AND pe.link_id IS NOT NULL
      ORDER BY pe.date DESC
    SQL

    events.each do |e|
      puts "  pe.id=#{e['id']} type=#{e['event_type']} product=#{e['product_id']} " \
           "usd_cents=#{e['usd_price_cents']} price_cents=#{e['price_cents']} " \
           "currency=#{e['currency']} link=#{e['link_path']} device=#{e['device_id']} " \
           "processed=#{e['processed']} store=#{e['store']} validated=#{e['webhook_validated']} " \
           "source=#{e['store_source']} date=#{e['date']}"
    end
    puts "  (none)" if events.empty?

    puts "\n=== revenue column type check ==="
    col_info = ActiveRecord::Base.connection.exec_query(<<~SQL)
      SELECT column_name, data_type, character_maximum_length
      FROM information_schema.columns
      WHERE table_name = 'link_daily_statistics' AND column_name = 'revenue'
    SQL
    col_info.each { |c| puts "  link_daily_statistics.revenue: #{c['data_type']}" }

    col_info2 = ActiveRecord::Base.connection.exec_query(<<~SQL)
      SELECT column_name, data_type
      FROM information_schema.columns
      WHERE table_name = 'visitor_daily_statistics' AND column_name = 'revenue'
    SQL
    col_info2.each { |c| puts "  visitor_daily_statistics.revenue: #{c['data_type']}" }

    puts "\n=== in_app_product_daily_statistics (all rows) ==="
    iap_stats = ActiveRecord::Base.connection.exec_query(<<~SQL)
      SELECT s.id, iap.product_id, s.event_date, s.platform,
             s.revenue, s.purchase_events, s.canceled_events,
             s.first_time_purchases, s.repeat_purchases, s.device_revenue
      FROM in_app_product_daily_statistics s
      JOIN in_app_products iap ON iap.id = s.in_app_product_id
      WHERE s.project_id = #{ActiveRecord::Base.connection.quote(project_id.to_i)}
      ORDER BY s.event_date DESC, iap.product_id
    SQL
    iap_stats.each do |r|
      puts "  product=#{r['product_id']} date=#{r['event_date']} platform=#{r['platform']} " \
           "revenue=#{r['revenue']} purchases=#{r['purchase_events']} cancels=#{r['canceled_events']} " \
           "first_time=#{r['first_time_purchases']} repeat=#{r['repeat_purchases']} dev_rev=#{r['device_revenue']}"
    end
    puts "  (none)" if iap_stats.empty?

    puts "\n=== ALL purchase_events (with transaction_ids) ==="
    all_events = ActiveRecord::Base.connection.exec_query(<<~SQL)
      SELECT pe.id, pe.event_type, pe.product_id, pe.usd_price_cents,
             pe.transaction_id, pe.original_transaction_id,
             pe.processed, pe.store, pe.webhook_validated, pe.date
      FROM purchase_events pe
      WHERE pe.project_id = #{ActiveRecord::Base.connection.quote(project_id.to_i)}
      ORDER BY pe.id
    SQL
    all_events.each do |e|
      puts "  pe.id=#{e['id']} type=#{e['event_type']} product=#{e['product_id']} " \
           "usd=#{e['usd_price_cents']} txn=#{e['transaction_id']&.[](0,20)}... " \
           "orig_txn=#{e['original_transaction_id']&.[](0,20)} " \
           "processed=#{e['processed']} store=#{e['store']} validated=#{e['webhook_validated']} date=#{e['date']}"
    end
    puts "  (none)" if all_events.empty?
  end
end
