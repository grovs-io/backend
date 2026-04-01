class VisitorDailyStatistic < ApplicationRecord
  belongs_to :visitor

  attribute :views,        :integer, default: 0
  attribute :opens,        :integer, default: 0
  attribute :installs,     :integer, default: 0
  attribute :reinstalls,   :integer, default: 0
  attribute :time_spent,   :integer, default: 0
  attribute :revenue,      :integer, default: 0
  attribute :reactivations,:integer, default: 0
  attribute :app_opens,    :integer, default: 0
  attribute :user_referred,:integer, default: 0

  scope :within_range, lambda { |start_date, end_date|
    where(event_date: start_date..end_date)
  }

  METRIC_COLUMNS = %i[
    views opens installs reinstalls time_spent revenue
    reactivations app_opens user_referred
  ].freeze

  def self.merge_visitors!(from_id:, to_id:)
    raise ArgumentError, "from and to must differ" if from_id.to_i == to_id.to_i

    transaction do
      where(visitor_id: from_id).find_each do |src|
        dst = find_or_initialize_by(visitor_id: to_id, event_date: src.event_date)

        METRIC_COLUMNS.each do |col|
          dst[col] = dst[col].to_i + src[col].to_i
        end

        # carry over aux fields if missing on the target—tweak as needed
        dst.project_id    ||= src.project_id
        dst.invited_by_id ||= src.invited_by_id

        dst.save!
      end

      # remove the old rows after merge
      where(visitor_id: from_id).delete_all
    end
  end

  def self.aggregate_by_visitor(start_date:, end_date:, sort_by: :views)
    raise ArgumentError, "Invalid sort key" unless METRIC_COLUMNS.include?(sort_by.to_sym)

    t = arel_table
    within_range(start_date, end_date)
      .group(:visitor_id)
      .select(
        :visitor_id,
        *METRIC_COLUMNS.map { |col| t[col].sum.as(col.to_s) }
      )
      .order(t[sort_by.to_sym].sum.desc)
  end
end
