class DownloadFileMailer < ApplicationMailer
  def download_file(file, user)
    @user = user
    @file = file

    mail(to: user.email, subject: "Data export - grovs")
  end
end
