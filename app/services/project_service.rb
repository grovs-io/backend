class ProjectService

  def initialize
  end

  def current_mau(instance)
    current_month = Date.today.month
    current_year = Date.today.year

    compute_mau(instance, current_month, current_year)
  end

  def last_month_mau(instance)
    previous_month = Date.today.prev_month.month
    previous_year = Date.today.prev_month.year

    compute_mau(instance, previous_month, previous_year)
  end

  def compute_mau(instance, month, year)
    start_date = Date.new(year, month, 1).beginning_of_day
    end_date = start_date.end_of_month.end_of_day

    compute_mau_for_dates(instance, start_date, end_date)
  end

  def compute_maus_per_month_total(instance, start_date, end_date)
    return 0 if instance.nil? || instance.test.nil? || instance.production.nil?

    total_maus = 0
    today = Date.current
    current_month_start = start_date.to_date.beginning_of_month
    end_date_d = end_date.to_date

    while current_month_start <= end_date_d
      current_month_end = [current_month_start.end_of_month, end_date_d].min
      completed = current_month_end < today.beginning_of_month
      cache_key = "mau:#{instance.id}:#{current_month_start.strftime('%Y-%m')}"

      cached = Rails.cache.read(cache_key)
      if cached
        total_maus += cached
      else
        count = compute_mau_for_dates(instance, current_month_start, current_month_end)
        # Completed months never change — cache 30 days. Current month — 10 minutes.
        ttl = completed ? 30.days : 10.minutes
        Rails.cache.write(cache_key, count, expires_in: ttl)
        total_maus += count
      end

      current_month_start = (current_month_start + 1.month).beginning_of_month
    end

    total_maus
  end

  private

  def compute_mau_for_dates(instance, start_date, end_date)
    if instance.nil? || instance.test.nil? || instance.production.nil?
      return 0
    end

    project_ids = [instance.test.id, instance.production.id]

    VisitorDailyStatistic
        .where(project_id: project_ids, event_date: start_date..end_date)
        .select(:visitor_id)
        .distinct
        .count
  end

end