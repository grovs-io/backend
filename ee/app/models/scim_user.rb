module ScimUser
  extend ActiveSupport::Concern

  class_methods do
    def scim_resource_type = Scimitar::Resources::User

    def scim_attributes_map
      {
        id: :id,
        externalId: :scim_external_id,
        userName: :scim_user_name,
        name: { givenName: :scim_given_name, familyName: :scim_family_name },
        emails: [{ match: "type", with: "work", using: { value: :scim_email, primary: true } }],
        active: :scim_active,
        displayName: :scim_display_name
      }
    end

    def scim_mutable_attributes = nil

    def scim_queryable_attributes
      { userName: { column: :scim_user_name }, externalId: { column: :scim_external_id },
        emails: { column: :email }, "emails.value" => { column: :email } }
    end

    def scim_timestamps_map = { created: :created_at, lastModified: :updated_at }
  end

  included do
    include Scimitar::Resources::Mixin
    attr_reader :scim_active_requested
  end

  # PUT clears attributes it does not carry; nil never overwrites an identity column.
  def scim_user_name=(value)
    super(value.to_s.strip.downcase) if value.present?
  end

  def scim_email = email
  def scim_display_name = name
  def scim_given_name = name.to_s.split(" ", 2)[0]
  def scim_family_name = name.to_s.split(" ", 2)[1]
  def scim_active = scim_active_requested.nil? ? scim_member? : scim_active_requested

  def scim_email=(value)
    self.email = value.to_s.strip.downcase if value.present?
  end

  def scim_display_name=(value)
    self.name = value if value.present?
  end

  def scim_given_name=(value)
    self.name = [value, scim_family_name].compact_blank.join(" ") if value.present?
  end

  def scim_family_name=(value)
    self.name = [scim_given_name, value].compact_blank.join(" ") if value.present?
  end

  def scim_active=(value)
    @scim_active_requested = ActiveModel::Type::Boolean.new.cast(value.to_s.downcase)
  end

  def scim_member?
    Current.scim_connection.present? && InstanceRole.exists?(user_id: id, instance_id: Current.scim_connection.instance_id)
  end
end
