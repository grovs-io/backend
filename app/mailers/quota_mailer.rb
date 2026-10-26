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

  def band_progress(email, usage_percentage, current_maus, plan_maus, instance_id)
    band_mail(email, usage_percentage, current_maus, plan_maus, instance_id, "You're nearing your plan's MAU band")
  end

  def band_exceeded(email, usage_percentage, current_maus, plan_maus, instance_id)
    band_mail(email, usage_percentage, current_maus, plan_maus, instance_id, "You've passed your plan's MAU band")
  end

  private

  def band_mail(email, usage_percentage, current_maus, plan_maus, instance_id, subject)
    @usage_percentage = usage_percentage
    @current_maus = current_maus
    @plan_maus = plan_maus
    @instance_id = instance_id
    project_name = Instance.find_by(id: instance_id)&.production&.name || "project #{instance_id}"
    mail(to: email, subject: "#{subject} (#{project_name}) - Grovs", reply_to: ENV["BILLING_ALERT_EMAIL"].presence)
  end
end
