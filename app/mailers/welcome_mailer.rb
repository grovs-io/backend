class WelcomeMailer < ApplicationMailer
  def welcome(user)
    @user = user
    mail(to: user.email, subject: 'Welcome!')
  end
end
  