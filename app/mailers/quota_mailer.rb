class QuotaMailer < ApplicationMailer
  include ActionView::Helpers::NumberHelper
  
  def quota_exceeded(user, usage_percentage, current_maus, plan_maus, instance_id)
    @usage_percentage = usage_percentage
    @current_maus = current_maus
    @plan_maus = plan_maus
    @user = user
    @instance_id = instance_id
    mail(to: user.email, subject: 'Quota exceeded - Grovs')
  end

  def quota_progress(user, usage_percentage, current_maus, plan_maus, instance_id)
    @usage_percentage = usage_percentage
    @current_maus = current_maus
    @plan_maus = plan_maus
    @user = user
    @instance_id = instance_id
    mail(to: user.email, subject: "You're nearing your monthly usage limit - Grovs")
  end
end
