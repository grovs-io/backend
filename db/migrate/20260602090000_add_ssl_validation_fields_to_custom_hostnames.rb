class AddSslValidationFieldsToCustomHostnames < ActiveRecord::Migration[8.1]
  # Adds the fields RefreshCustomHostnameStatusJob persists from Cloudflare:
  #   - ssl_method                          — "txt" (DNS-01) or "http" (legacy)
  #   - ssl_validation_txt_records          — JSONB array, one entry per CA challenge
  #                                           (multi-CA dual issuance can emit >1)
  #   - ownership_verification_txt_name/_value — second TXT (Hostname Pre-Validation)
  #                                              on zones with pre-validation enabled
  #
  # ssl_validation_txt_records is JSONB (not two scalar columns) so multi-CA dual
  # issuance — CF returning a separate ACME challenge per cert authority — round-trips
  # correctly. Scalar columns collapsed that to one record and silently dropped the rest.
  def change
    change_table :custom_hostnames, bulk: true do |t|
      t.string :ssl_method
      t.jsonb  :ssl_validation_txt_records, default: [], null: false
      t.string :ownership_verification_txt_name
      t.string :ownership_verification_txt_value
    end
  end
end
