namespace :grovs do
  desc "Create the bootstrap administrator when a self-hosted install has no users (idempotent)"
  task ensure_bootstrap_admin: :environment do
    next unless Grovs.self_hosted?
    next if User.exists?

    email    = ENV["BOOTSTRAP_ADMIN_EMAIL"].to_s.strip.downcase
    password = ENV["BOOTSTRAP_ADMIN_PASSWORD"].to_s

    if email.empty? || password.empty?
      abort <<~MSG
        No user accounts exist and BOOTSTRAP_ADMIN_EMAIL/BOOTSTRAP_ADMIN_PASSWORD are not set.
        Public sign-up is disabled on self-hosted and SSO will not create the first account,
        so nobody could log in. Set both variables and run the migrate task again.
      MSG
    end

    User.create!(email: email, password: password, name: "Admin")
    puts "created bootstrap administrator #{email}"
  end
end
