require_relative "../../../test/contracts/external_api_contracts"

module ApiContracts
  NUMBER_OR_NULL = { "type" => %w[number null] }.freeze
  INT_OR_NULL = { "type" => %w[integer null] }.freeze
  # One of event, screen, system or purchase; products only with purchase.
  GOAL = { "type" => "object", "additionalProperties" => false, "required" => %w[window_hours], "minProperties" => 2, "maxProperties" => 3,
           "properties" => { "event" => STRING, "screen" => STRING, "system" => STRING, "purchase" => { "type" => "boolean" },
                             "products" => { "type" => "array", "items" => STRING }, "window_hours" => { "type" => "integer" } } }.freeze
  EXPERIMENT_GROUP = strict_object(
    required: %w[id exposed clicked converted conversion_rate click_rate confidence revenue_cents revenue_per_person_cents],
    properties: { "id" => STRING, "exposed" => { "type" => "integer" }, "clicked" => INT_OR_NULL, "converted" => INT_OR_NULL,
                  "conversion_rate" => NUMBER_OR_NULL, "click_rate" => NUMBER_OR_NULL, "confidence" => NUMBER_OR_NULL,
                  "revenue_cents" => { "type" => "integer" }, "revenue_per_person_cents" => INT_OR_NULL }
  )
  EXPERIMENT = strict_object(
    required: %w[goal control_group project_control_group test_share groups lift added_conversions confidence more_people_needed
                  revenue_lift added_revenue_cents],
    properties: { "goal" => { "oneOf" => [{ "type" => "null" }, GOAL] },
                  "control_group" => INT_OR_NULL, "project_control_group" => { "type" => "integer" }, "test_share" => INT_OR_NULL,
                  "groups" => { "type" => "array", "items" => EXPERIMENT_GROUP }, "lift" => NUMBER_OR_NULL,
                  "added_conversions" => INT_OR_NULL, "confidence" => NUMBER_OR_NULL, "more_people_needed" => INT_OR_NULL,
                  "revenue_lift" => NUMBER_OR_NULL, "added_revenue_cents" => INT_OR_NULL }
  )
end
