function configureDefaultPage() {
  config = desktopJSONData("desktop");
  configToApply = config.linksquared;

  setDesktopUIData(
    configToApply.title,
    configToApply.image,
    configToApply.qr,
    configToApply.android,
    configToApply.ios
  );

  if (configToApply == null) {
    // There's redirect link
    navigateToFallback(config.fallback, "", true);
    return false;
  }
}

function handleMac() {
  configToApply = config.mac;
  let allNull =
    configToApply?.deeplink == null &&
    configToApply?.appstore == null &&
    configToApply?.fallback == null;

  if (configToApply == null || allNull) {
    return false;
  }

  configureOpenView(
    configToApply.title,
    configToApply.image,
    configToApply.deeplink,
    configToApply.appstore,
    configToApply.fallback,
    "Open in AppStore",
    false,
    null,
    false
  );

  return true;
}

function handleWindows() {
  config = desktopJSONData("desktop");
  configToApply = config.windows;

  let allNull =
    configToApply?.deeplink == null &&
    configToApply?.appstore == null &&
    configToApply?.fallback == null;

  if (configToApply == null || allNull) {
    return false;
  }

  configureOpenView(
    configToApply.title,
    configToApply.image,
    configToApply.deeplink,
    configToApply.appstore,
    configToApply.fallback,
    "Open in Windows Store",
    false,
    null,
    false
  );

  return true;
}

function handleDesktop() {
  config = desktopJSONData("desktop");
  setDownloadViewHidden(true);

  if (isMac() && handleMac() == true) {
    return true;
  }

  if (isWindows() && handleWindows() == true) {
    return true;
  }

  return configureDefaultPage();
}
