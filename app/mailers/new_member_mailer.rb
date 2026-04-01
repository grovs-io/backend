class NewMemberMailer < ApplicationMailer
  def new_member(instance, user)
    @user = user
    @instance = instance

    mail(to: user.email, subject: "New project access - grovs.")
  end
end
  