class CustomDeviseMailer < Devise::Mailer
  protected
  
  def subject_for(key)
    if key.to_s == "invitation_instructions"
      return "You're invited to join Grovs."
    end

    if key.to_s == "reset_password_instructions"
      return "Change password link for Grovs."
    end
  
    super
  end
end