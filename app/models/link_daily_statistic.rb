class LinkDailyStatistic < ApplicationRecord
  belongs_to :link

  attribute :views,        :integer, default: 0
  attribute :opens,        :integer, default: 0
  attribute :installs,     :integer, default: 0
  attribute :reinstalls,   :integer, default: 0
  attribute :time_spent,   :integer, default: 0
  attribute :reactivations,:integer, default: 0
  attribute :app_opens,    :integer, default: 0
  attribute :user_referred,:integer, default: 0
  attribute :revenue,      :integer, default: 0

  METRIC_COLUMNS = %i[
    views opens installs reinstalls time_spent revenue
    reactivations app_opens user_referred
  ].freeze

  scope :within_range, lambda { |start_date, end_date|
    where(event_date: start_date..end_date)
  }

  def self.aggregate_by_link(start_date:, end_date:, sort_by: :views)
    valid_columns = %i[
      views opens installs reinstalls time_spent revenue
      reactivations app_opens user_referred
    ]

    raise ArgumentError, "Invalid sort key" unless valid_columns.include?(sort_by.to_sym)

    within_range(start_date, end_date)
      .group(:link_id)
      .select(
        :link_id,
        *valid_columns.map { |col| "SUM(#{col}) AS #{col}" }
      )
      .order("#{sort_by} DESC")
  end
end
