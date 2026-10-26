require "json"

module InAppSharedCases
  DIR = File.expand_path("../../config/in_app", __dir__)
  CASE_KEYS = %w[global_caps synced_at not_ready].freeze

  module_function

  def file = JSON.parse(File.read(File.join(DIR, "cases.json")))
  def definition_schema = JSON.parse(File.read(File.join(DIR, "definition.schema.json")))
  def cases_schema = JSON.parse(File.read(File.join(DIR, "cases.schema.json")))

  # Objects merge key by key; arrays and scalars replace.
  def merge(base, over)
    base.merge(over) { |_, a, b| a.is_a?(Hash) && b.is_a?(Hash) ? merge(a, b) : b }
  end

  def expanded
    data = file
    data.fetch("cases").map do |raw|
      merge(data.fetch("base_case"), raw.slice(*CASE_KEYS)).merge(
        "name" => raw.fetch("name"),
        "off_schema" => raw.fetch("off_schema", []),
        "device" => merge(data.fetch("base_device"), raw.fetch("device", {})),
        "campaigns" => raw.fetch("campaigns").map { |c| merge(data.fetch("base_campaign"), c) },
        "steps" => raw.fetch("steps")
      )
    end
  end
end
