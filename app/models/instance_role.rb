class InstanceRole < ApplicationRecord
  belongs_to :instance
  belongs_to :user

  validates :role, inclusion: { in: Grovs::Roles::ALL }

  def self.is_user_admin(user, instance)
    found = self.role_for_user_and_instance(user, instance)
  
    if found && found.role == Grovs::Roles::ADMIN
      return true
    end

    false
  end
    
  def self.role_for_user_and_instance(user, instance)
    return nil if !user || !instance

    find_by(user_id: user.id, instance_id: instance.id)
  end
end
