# frozen_string_literal: true

# Recreates the mobile automation projects on this environment.
#
# The test environment DB gets wiped periodically, which deletes the instances
# the automation repos depend on. This restores the exact instance / project /
# domain / link setup those suites expect:
#
#   - Android Maestro suite (grovs-android-automation-app, maestro/config.js):
#     project host grov0812.<DOMAIN_LIVE> with the dashboard links
#     default-test, web-redirect-test, etc. (both -test and -dev variants),
#     and NO active "invalid-link" path.
#   - iOS Maestro suite (grovs-ios-automation-app, maestro/config.js): project
#     host grov3cf9.<DOMAIN_LIVE> with the same dashboard link set. The same
#     instance also serves the Android suite's prod/appss config, so it gets
#     BOTH app configs; its web-redirect links send iOS to android.com and
#     Android to grovs.io (what each suite asserts).
#   - Android JUnit e2e suite (grovs-android-e2e-tests, env-test.properties):
#     project host e2etests.<DOMAIN_LIVE> with link path e2e-1.
#
# Usage:
#   bundle exec rake automation_projects:recreate_android_maestro_project
#   bundle exec rake automation_projects:recreate_ios_maestro_project
#   bundle exec rake automation_projects:recreate_android_e2e_project
#   bundle exec rake automation_projects:recreate_all_projects
#
# Env overrides (defaults match the automation repos' committed config):
#   AUTOMATION_USER_EMAIL              (default automation@grovs.io)
#   AUTOMATION_USER_PASSWORD           (random + printed if user is created without it)
#   AUTOMATION_ANDROID_MAESTRO_API_KEY / _URI_SCHEME / _SUBDOMAIN
#   AUTOMATION_IOS_MAESTRO_API_KEY / _URI_SCHEME / _SUBDOMAIN
#   AUTOMATION_E2E_API_KEY / _URI_SCHEME / _SUBDOMAIN / _LINK_PATH
#   AUTOMATION_ANDROID_IDENTIFIER      (default com.instagram.android)
#   AUTOMATION_ANDROID_SHA256S         (comma-separated cert fingerprints for assetlinks.json;
#                                       falls back to the automation build cert F5:09:10:…:94:43)
#   AUTOMATION_IOS_BUNDLE_ID           (default com.appssemble.BluetoothDeviceFinder)
#   AUTOMATION_IOS_APP_PREFIX          (Apple team ID for AASA, default WZYAY65GLB)

namespace :automation_projects do
  desc "Recreate the Android Maestro automation instance, project and dashboard links"
  task recreate_android_maestro_project: :environment do
    AutomationProjectsSeeder.recreate_android_maestro
  end

  desc "Recreate the iOS Maestro automation instance, project and dashboard links"
  task recreate_ios_maestro_project: :environment do
    AutomationProjectsSeeder.recreate_ios_maestro
  end

  desc "Recreate the Android JUnit e2e instance, project and e2e-1 link"
  task recreate_android_e2e_project: :environment do
    AutomationProjectsSeeder.recreate_e2e
  end

  desc "Recreate all mobile automation projects (Android Maestro + iOS Maestro + JUnit e2e)"
  task recreate_all_projects: %i[
    recreate_android_maestro_project
    recreate_ios_maestro_project
    recreate_android_e2e_project
  ]
end

module AutomationProjectsSeeder
  ANDROID_SUITE_REDIRECT_URL = "https://grovs.io"
  IOS_SUITE_REDIRECT_URL = "https://android.com"
  UTM_TRACKING = {
    tracking_source: "automation-campaign-source",
    tracking_medium: "automation-campaign-medium",
    tracking_campaign: "automation-campaign-name"
  }.freeze

  module_function

  def recreate_android_maestro
    api_key = ENV["AUTOMATION_ANDROID_MAESTRO_API_KEY"] ||
              "grovsa_02ac0cdc197ee7613ddfe48eb2075a82e88956cdd3bbc0996c96501d5dac6c37"
    uri_scheme = ENV["AUTOMATION_ANDROID_MAESTRO_URI_SCHEME"] || "demo0fac065ec1eb"
    subdomain = ENV["AUTOMATION_ANDROID_MAESTRO_SUBDOMAIN"] || "grov0812"

    puts "=== Recreating Android Maestro automation project (#{subdomain}.#{live_domain}) ==="

    ActiveRecord::Base.transaction do
      instance = ensure_instance(name: "Android Automation", api_key: api_key,
                                 uri_scheme: uri_scheme, subdomain: subdomain,
                                 android: true, ios: false)
      project = production_project(instance)

      # Android-only project: every platform redirects where the Android suite asserts.
      redirect_urls = { ios: ANDROID_SUITE_REDIRECT_URL, android: ANDROID_SUITE_REDIRECT_URL,
                        desktop: ANDROID_SUITE_REDIRECT_URL }
      ensure_links(project, maestro_link_specs(redirect_urls))
      ensure_link_absent(project, "invalid-link")
    end

    puts "Done. Android Maestro links live at https://#{subdomain}.#{live_domain}/"
  end

  def recreate_ios_maestro
    api_key = ENV["AUTOMATION_IOS_MAESTRO_API_KEY"] ||
              "grovsa_2201bb4ab56b3d8110bec9480837541dcbb61d791e3e8383f080ce0ccd5b6991"
    uri_scheme = ENV["AUTOMATION_IOS_MAESTRO_URI_SCHEME"] || "grovsa50b6de59903f"
    subdomain = ENV["AUTOMATION_IOS_MAESTRO_SUBDOMAIN"] || "grov3cf9"

    puts "=== Recreating iOS Maestro automation project (#{subdomain}.#{live_domain}) ==="

    ActiveRecord::Base.transaction do
      # This instance also serves the Android suite's prod/appss config, so it
      # needs both platform app configs.
      instance = ensure_instance(name: "Grovs Automation", api_key: api_key,
                                 uri_scheme: uri_scheme, subdomain: subdomain,
                                 android: true, ios: true)
      project = production_project(instance)

      redirect_urls = { ios: IOS_SUITE_REDIRECT_URL, android: ANDROID_SUITE_REDIRECT_URL,
                        desktop: ANDROID_SUITE_REDIRECT_URL }
      ensure_links(project, maestro_link_specs(redirect_urls))
      ensure_link_absent(project, "invalid-link")
    end

    puts "Done. iOS Maestro links live at https://#{subdomain}.#{live_domain}/"
  end

  def recreate_e2e
    api_key = ENV["AUTOMATION_E2E_API_KEY"] ||
              "grovse_6bd3ca976ca23358d37c07209d1ba91713fd5e90e49ed3e21c66747ecc70b9ae"
    uri_scheme = ENV["AUTOMATION_E2E_URI_SCHEME"] || "e2etests4a1f9c0b"
    subdomain = ENV["AUTOMATION_E2E_SUBDOMAIN"] || "e2etests"

    puts "=== Recreating JUnit e2e automation project (#{subdomain}.#{live_domain}) ==="

    ActiveRecord::Base.transaction do
      instance = ensure_instance(name: "Android E2E Tests", api_key: api_key,
                                 uri_scheme: uri_scheme, subdomain: subdomain,
                                 android: true, ios: false)
      project = production_project(instance)

      ensure_links(project, [{ path: ENV["AUTOMATION_E2E_LINK_PATH"] || "e2e-1" }])
    end

    puts "Done. E2E link lives at https://#{subdomain}.#{live_domain}/e2e-1"
  end

  # One link spec per maestro/config.js entry. The same project serves both the
  # "test" and "prodDevelopment" maestro environments, so both suffixes exist.
  def maestro_link_specs(redirect_urls)
    %w[test dev].flat_map do |suffix|
      [
        { path: "default-#{suffix}" },
        { path: "default-preview-#{suffix}", preview: true },
        { path: "web-redirect-#{suffix}", redirects: redirect_urls, open_app: false },
        { path: "web-redirect-preview-#{suffix}", redirects: redirect_urls, open_app: false, preview: true },
        { path: "app-or-web-fallback-#{suffix}", redirects: redirect_urls, open_app: true },
        { path: "app-or-web-fallback-preview-#{suffix}", redirects: redirect_urls, open_app: true, preview: true },
        { path: "web-redirect-utm-#{suffix}", redirects: redirect_urls, open_app: false, utm: true },
        { path: "web-redirect-preview-utm-#{suffix}", redirects: redirect_urls, open_app: false, preview: true, utm: true }
      ]
    end
  end

  # Mirrors InstanceProvisioningService#create but with fixed identifiers so the
  # automation config (API keys, hosts, uri scheme) keeps working across wipes.
  def ensure_instance(name:, api_key:, uri_scheme:, subdomain:, android:, ios:)
    user = ensure_user

    instance = Instance.find_by(api_key: api_key)
    if instance
      puts "  Instance #{api_key[0, 12]}… already exists (id=#{instance.id})"
      instance.update!(uri_scheme: uri_scheme) if instance.uri_scheme != uri_scheme
    else
      instance = Instance.create!(api_key: api_key, uri_scheme: uri_scheme)
      puts "  Created instance id=#{instance.id} (uri_scheme=#{uri_scheme})"
    end

    prod = Project.find_by(instance_id: instance.id, test: false) ||
           Project.create!(instance: instance, name: name, test: false, identifier: api_key)
    test = Project.find_by(instance_id: instance.id, test: true) ||
           Project.create!(instance: instance, name: "#{name}-test", test: true, identifier: "test_#{api_key}")

    # The SDK authenticates with PROJECT-KEY == project identifier — keep them
    # pinned to the API key even if the surviving rows drifted.
    prod.update!(identifier: api_key) if prod.identifier != api_key
    test.update!(identifier: "test_#{api_key}") if test.identifier != "test_#{api_key}"

    ensure_domain(prod, live_domain, subdomain)
    ensure_domain(test, test_domain, subdomain)

    [prod, test].each { |project| RedirectConfig.find_or_create_by!(project_id: project.id) }

    InstanceRole.find_or_create_by!(instance_id: instance.id, user_id: user.id) do |role|
      role.role = Grovs::Roles::ADMIN
    end

    ensure_android_application(instance) if android
    ensure_ios_application(instance) if ios
    instance.create_desktop_configuration

    [prod, test].each do |project|
      ensure_store_redirect(project, Grovs::Platforms::ANDROID) if android
      ensure_store_redirect(project, Grovs::Platforms::IOS) if ios
    end

    instance
  end

  def production_project(instance)
    Project.find_by!(instance_id: instance.id, test: false)
  end

  def ensure_user
    email = ENV["AUTOMATION_USER_EMAIL"] || "automation@grovs.io"
    user = User.find_for_email(email)
    return user if user

    password = ENV["AUTOMATION_USER_PASSWORD"] || SecureRandom.base58(20)
    user = User.create!(email: email, password: password, password_confirmation: password,
                        name: "Grovs Automation")
    if ENV["AUTOMATION_USER_PASSWORD"]
      puts "  Created user #{email}"
    else
      puts "  Created user #{email} with generated password: #{password} (store it now)"
    end
    user
  end

  def ensure_domain(project, domain_name, subdomain)
    clash = Domain.where(domain: domain_name, subdomain: subdomain)
                  .where.not(project_id: project.id).first
    if clash
      abort "  ABORT: #{subdomain}.#{domain_name} is already taken by project id=#{clash.project_id}. " \
            "Delete that project or override the AUTOMATION_*_SUBDOMAIN env var."
    end

    domain = project.domain
    if domain
      if domain.domain != domain_name || domain.subdomain != subdomain
        domain.update!(domain: domain_name, subdomain: subdomain)
      end
    else
      Domain.create!(project_id: project.id, domain: domain_name, subdomain: subdomain)
      puts "  Domain #{subdomain}.#{domain_name} -> project id=#{project.id}"
    end
  end

  # Signing cert fingerprint of the automation app builds — served in
  # assetlinks.json so Android App Links (autoVerify) verify. Only used when
  # AUTOMATION_ANDROID_SHA256S isn't passed and the config has none yet.
  FALLBACK_ANDROID_SHA256 =
    "F5:09:10:F7:51:28:CA:04:51:1F:E4:C6:3D:68:E3:A8:22:64:B5:A9:C1:9C:ED:5D:9B:F6:9F:7F:43:31:94:43"

  def ensure_android_application(instance)
    identifier = ENV["AUTOMATION_ANDROID_IDENTIFIER"] || "com.instagram.android"
    env_sha256s = (ENV["AUTOMATION_ANDROID_SHA256S"] || "").split(",").map(&:strip).reject(&:blank?)

    application = instance.application_for_platform(Grovs::Platforms::ANDROID)
    config = AndroidConfiguration.find_by(application_id: application.id)

    if config
      config.update!(identifier: identifier) if config.identifier != identifier
      if env_sha256s.present? && config.sha256s != env_sha256s
        config.update!(sha256s: env_sha256s)
      elsif config.sha256s.blank?
        config.update!(sha256s: [FALLBACK_ANDROID_SHA256])
      end
    else
      sha256s = env_sha256s.presence || [FALLBACK_ANDROID_SHA256]
      AndroidConfiguration.create!(application: application, identifier: identifier, sha256s: sha256s)
      puts "  Android app configured (#{identifier})"
    end
  end

  def ensure_ios_application(instance)
    bundle_id = ENV["AUTOMATION_IOS_BUNDLE_ID"] || "com.appssemble.BluetoothDeviceFinder"
    app_prefix = ENV["AUTOMATION_IOS_APP_PREFIX"] || "WZYAY65GLB"

    application = instance.application_for_platform(Grovs::Platforms::IOS)
    config = IosConfiguration.find_by(application_id: application.id)

    if config
      config.update!(bundle_id: bundle_id) if config.bundle_id != bundle_id
      config.update!(app_prefix: app_prefix) if config.app_prefix != app_prefix
    else
      IosConfiguration.create!(application: application, bundle_id: bundle_id, app_prefix: app_prefix)
      puts "  iOS app configured (#{app_prefix}.#{bundle_id})"
    end
  end

  # Default links (no custom redirect) must send uninstalled devices to the
  # store page of the configured app for the platform's phone variation.
  def ensure_store_redirect(project, platform)
    redirect = project.redirect_config.redirect_for_platform_and_variation(
      platform, Grovs::Platforms::PHONE
    )
    redirect.update!(enabled: true, appstore: true) unless redirect.enabled && redirect.appstore
  end

  def ensure_links(project, specs)
    service = LinkManagementService.new(project: project)
    domain = project.domain

    specs.each do |spec|
      attrs = link_attrs_for(spec)
      custom_redirects = custom_redirects_for(spec)

      link = Link.find_by(domain_id: domain.id, path: spec[:path], active: true)
      if link
        service.update(link: link, link_attrs: attrs, custom_redirects: custom_redirects)
        puts "  ~ /#{spec[:path]} (already existed, config re-applied)"
      else
        service.create(link_attrs: attrs, custom_redirects: custom_redirects)
        puts "  + /#{spec[:path]}"
      end
    end
  end

  def link_attrs_for(spec)
    preview = spec.fetch(:preview, false)
    tracking = spec[:utm] ? UTM_TRACKING : { tracking_source: nil, tracking_medium: nil, tracking_campaign: nil }

    {
      path: spec[:path],
      name: spec[:path],
      title: "Grovs Automation",
      active: true,
      show_preview_android: preview,
      show_preview_ios: preview
    }.merge(tracking)
  end

  # Passing explicit nils makes LinkManagementService drop stale custom
  # redirects when a link is being converged back to a default (store) link.
  def custom_redirects_for(spec)
    urls = spec[:redirects]
    return { ios: nil, android: nil, desktop: nil } unless urls

    open_app = spec.fetch(:open_app, false)
    {
      ios: { "url" => urls[:ios], "open_app_if_installed" => open_app },
      android: { "url" => urls[:android], "open_app_if_installed" => open_app },
      desktop: { "url" => urls[:desktop] }
    }
  end

  # maestro/config.js points dashboardInvalidPath here — it must NOT resolve.
  def ensure_link_absent(project, path)
    link = Link.find_by(domain_id: project.domain.id, path: path, active: true)
    return unless link

    LinkManagementService.new(project: project).archive(link: link)
    puts "  - /#{path} archived (must stay invalid for the suite)"
  end

  def live_domain
    Grovs::Domains::LIVE.split(":").first
  end

  def test_domain
    Grovs::Domains::TEST.split(":").first
  end
end
