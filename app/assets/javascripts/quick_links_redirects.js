function handleIOS(phone, tablet) {
  if (isIphone()) {
    goToLinkWithFallback(phone, null);
    return true;
  }

  if (isIpad()) {
    goToLinkWithFallback(tablet, phone);
    return true;
  }

  return false;
}

function handleAndroid(phone, tablet) {
  if (isAndroidPhone()) {
    goToLinkWithFallback(phone, null);
    return true;
  }

  if (isAndroidTablet()) {
    goToLinkWithFallback(tablet, phone);
    return true;
  }

  return false;
}

function handleDesktop(desktop, mac, windows, linux) {
  if (isMac()) {
    goToLinkWithFallback(mac, desktop);
    return true;
  }

  if (isWindows()) {
    goToLinkWithFallback(windows, desktop);
    return true;
  }

  if (isLinux()) {
    goToLinkWithFallback(linux, desktop);
    return true;
  }

  return false;
}

function goToLinkWithFallback(link, fallback) {
  if (link) {
    window.location.href = link;
  } else {
    window.location.href = fallback;
  }
}

function handleQuickLinkRedirect(
  ios_phone,
  ios_tablet,
  android_phone,
  android_tablet,
  desktop,
  mac,
  windows,
  linux
) {
  var handled = false;
  handled = handleIOS(ios_phone, ios_tablet);
  if (handled) {
    return;
  }

  handled = handleAndroid(android_phone, android_tablet);
  if (handled) {
    return;
  }

  handled = handleDesktop(desktop, mac, windows, linux);
  if (handled) {
    return;
  }

  windows.location.href = "https://linksquared.io";
}
