function configureAndroidData(
  title,
  image,
  deeplink,
  appstore,
  fallback,
  hasAppInstalled,
  openAppIfInstalled,
  showPreview
) {
  configureOpenView(
    title,
    image,
    deeplink,
    appstore,
    fallback,
    "Open Application",
    hasAppInstalled,
    openAppIfInstalled,
    showPreview
  );
}

function handleConfigPhone() {
  config = mobileJSONData("android");
  phoneConfig = config.phone;
  if (phoneConfig == null) {
    return false;
  }

  configureAndroidData(
    phoneConfig.title,
    phoneConfig.image,
    phoneConfig.deeplink,
    phoneConfig.appstore,
    phoneConfig.fallback,
    phoneConfig.has_app_installed,
    phoneConfig.open_app_if_installed,
    phoneConfig.show_preview
  );

  return true;
}

function handleConfigTablet() {
  config = mobileJSONData("android");
  tabletConfig = config.tablet;
  if (tabletConfig == null) {
    // There's no tablet specific config, resort to the mobile one
    return handleConfigPhone();
  }

  configureAndroidData(
    tabletConfig.title,
    tabletConfig.image,
    tabletConfig.deeplink,
    tabletConfig.appstore,
    tabletConfig.fallback,
    tabletConfig.has_app_installed,
    tabletConfig.open_app_if_installed,
    tabletConfig.show_preview
  );

  return true;
}

function handleAndroidIfNeeded() {
  redirectIfQueryParamExists();
  setDownloadViewHidden(true);

  config = mobileJSONData("android");

  if (config == null) {
    return false;
  }

  if (isAndroidPhone() && handleConfigPhone() == true) {
    return true;
  }

  if (isAndroidTablet() && handleConfigTablet() == true) {
    return true;
  }

  navigateToFallback(config.phone.fallback, "", true);
  return false;
}
