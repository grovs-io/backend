namespace :users do
  desc "Disable 2FA for users whose otp_secret is corrupted (not valid Base32). " \
       "This happens when the ActiveRecord encryption keys change and " \
       "`support_unencrypted_data: true` causes raw ciphertext JSON to leak through " \
       "as plaintext, breaking ROTP/Google Authenticator. Affected users must " \
       "re-enroll 2FA after this task runs. Set DRY_RUN=true to preview without writing."
  task fix_broken_otp_secrets: :environment do
    dry_run = ENV.fetch("DRY_RUN", "false") == "true"

    would_fix = 0
    fixed = 0
    skipped_valid = 0
    errors = []

    puts dry_run ? "DRY RUN — no changes will be written" : "Applying fixes to database"

    User.where.not(otp_secret: nil).find_each do |user|
      secret =
        begin
          user.otp_secret
        rescue => e
          errors << "User #{user.id} (#{user.email}): raised #{e.class}: #{e.message}"
          next
        end

      # Skip users whose secret is already valid Base32 (shared predicate with
      # UserAccountService.setup_2fa — single source of truth for what counts
      # as a valid TOTP secret).
      if UserAccountService.valid_otp_secret?(secret)
        skipped_valid += 1
        next
      end

      # Corrupted: null otp_secret + disable 2FA so the user can log in with
      # password alone and re-enroll. update_columns bypasses callbacks and the
      # AR encryption layer, writing NULL directly to the DB column.
      if dry_run
        puts "Would fix User #{user.id} (#{user.email}) — otp_required_for_login=#{user.otp_required_for_login}"
        would_fix += 1
      else
        user.update_columns(
          otp_secret: nil,
          otp_required_for_login: false,
          consumed_timestep: nil
        )
        puts "Fixed User #{user.id} (#{user.email})"
        fixed += 1
      end
    end

    puts "\nDone."
    if dry_run
      puts "  Would fix:       #{would_fix} (dry run — nothing written)"
    else
      puts "  Fixed:           #{fixed}"
    end
    puts "  Skipped (valid): #{skipped_valid}"
    puts "  Errors:          #{errors.size}"
    errors.each { |e| puts "    ERROR: #{e}" }
  end
end
