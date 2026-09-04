module AuditActor
  module_function

  def user(user, via:)
    { "type" => "user", "id" => user.id, "email" => user.email, "via" => via }
  end

  def admin_key
    { "type" => "admin_key", "id" => nil, "email" => nil, "via" => "admin_key" }
  end

  def api_key(instance)
    { "type" => "api_key", "id" => instance.id, "email" => nil, "via" => "api_key" }
  end

  def system(job_name)
    { "type" => "system", "id" => job_name, "email" => nil, "via" => "system" }
  end

  def scim_token(connection)
    { "type" => "scim_token", "id" => connection.id, "email" => nil, "via" => "scim" }
  end
end
