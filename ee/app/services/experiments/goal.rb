# What counts as a conversion: a custom event, a screen, a system event or a store purchase, inside a window after exposure.
module Experiments::Goal
  WINDOWS = [24, 72, 168].freeze
  PURCHASE_WINDOWS = (WINDOWS + [720]).freeze
  NAMES = %w[event screen system purchase].freeze
  KEYS = (NAMES + %w[window_hours products]).freeze
  MAX_PRODUCTS = 20
  SYSTEM = [Grovs::Events::INSTALL, Grovs::Events::REINSTALL, Grovs::Events::APP_OPEN, Grovs::Events::OPEN, Grovs::Events::VIEW,
            Grovs::Events::REACTIVATION].freeze

  module_function

  def problem(goal)
    return "must be an object" unless goal.is_a?(Hash)
    return "holds unknown fields" unless (goal.keys - KEYS).empty?
    return "needs one event or screen name of up to 100 characters, one system event, or purchase: true" unless named?(goal)
    return "cannot be a message event" if goal.key?("event") && Grovs::Events::MESSAGE_EVENT_NAMES.include?(name(goal))
    return "products is only for a purchase goal" if goal.key?("products") && !purchase?(goal)
    return "products must be 1 to #{MAX_PRODUCTS} product ids of up to 100 characters" if goal.key?("products") && !products?(goal["products"])
    return "window_hours must be 24, 72, 168 or 720" if purchase?(goal) && !PURCHASE_WINDOWS.include?(goal["window_hours"])

    "window_hours must be 24, 72 or 168" unless purchase?(goal) || WINDOWS.include?(goal["window_hours"])
  end

  def purchase?(goal) = goal["purchase"] == true

  def named?(goal)
    return false unless NAMES.count { |k| goal.key?(k) } == 1
    return purchase?(goal) if goal.key?("purchase")
    return SYSTEM.include?(goal["system"]) if goal.key?("system")

    (goal["event"] || goal["screen"]).is_a?(String) && name(goal).length.between?(1, 100)
  end

  def products?(list)
    list.is_a?(Array) && list.size.between?(1, MAX_PRODUCTS) && list.all? { |p| p.is_a?(String) && p.strip.length.between?(1, 100) }
  end

  def name(goal) = (goal["event"] || goal["screen"] || goal["system"]).to_s.strip

  # Screens match in any case, as journeys' entries, waits, splits and exits do.
  def sql(goal, param = "goal")
    return "event_type = {#{param}:String}" if goal.key?("system")
    return "event_type = 'screen_view' AND lower(screen_name) = lower({#{param}:String})" if goal.key?("screen")

    "event_type = 'custom' AND event_name = {#{param}:String}"
  end
end
