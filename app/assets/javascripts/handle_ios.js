function configureiOSData(
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
    "Get the app",
    hasAppInstalled,
    openAppIfInstalled,
    showPreview
  );
}

function handleConfigPhone() {
  config = mobileJSONData("ios");
  phoneConfig = config.phone;
  if (phoneConfig == null) {
    return false;
  }

  configureiOSData(
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
  config = mobileJSONData("ios");
  tabletConfig = config.tablet;
  if (tabletConfig == null) {
    // There's no tablet specific config, resort to the mobile one
    return handleConfigPhone();
  }

  configureiOSData(
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

function handleiOSIfNeeded() {
  redirectIfQueryParamExists();
  setDownloadViewHidden(true);

  config = mobileJSONData("ios");
  if (config == null) {
    return false;
  }

  if (isIphone() && handleConfigPhone() == true) {
    return true;
  }

  if (isIpad() && handleConfigTablet() == true) {
    return true;
  }

  navigateToFallback(config.phone.fallback, "", true);
  return false;
}
