module PushCampaignFixtures
  SEGMENT_DEFINITION = { "version" => 1, "operator" => "or", "groups" => [{ "operator" => "and", "conditions" => [
    { "type" => "event", "any" => true, "window" => { "last_days" => 30 } }
  ] }] }.freeze
end
