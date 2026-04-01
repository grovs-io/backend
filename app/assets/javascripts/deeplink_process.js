function appendParamToURL(url, paramName, paramValue) {
  // Create a URL object from the input string
  const urlObj = new URL(url);

  // Add or update the query parameter
  urlObj.searchParams.set(paramName, paramValue);

  // Return the updated URL as a string
  return urlObj.toString();
}

function navigateToFallback(link, title, directRedirect) {
  if (link == null || link.length == 0) {
    return;
  }

  if (directRedirect) {
    // Defer redirect until full load
    if (document.readyState === "complete") {
      // Page is fully loaded — go now
      doRedirect(link);
    } else {
      // Wait for full load
      window.addEventListener("load", function onLoad() {
        window.removeEventListener("load", onLoad); // clean up listener
        doRedirect(link);
      });
    }
    return;
  }

  appStoreButtonHidden(false);
  if (isAtLeastSafari1230()) {
    if (window.confirm(title)) {
      goToLink(link);
    }
  } else {
    goToLink(link);
  }
}

function doRedirect(link) {
  const path = window.location.pathname.replace(/^\//, "");
  let new_link = link;

  if (!new_link.startsWith("http://") && !new_link.startsWith("https://")) {
    new_link = "http://" + new_link;
  }

  new_link = appendParamToURL(new_link, "linksquared", path);
  new_link = appendParamToURL(new_link, "Grovs", path);

  window.top.location = new_link;
}

function navigateToDeeplink(link) {
  goToLink(link);
}

function handleFallback(appstore, fallback, openDeepLinkText) {
  if (appstore != null) {
    navigateToFallback(appstore, openDeepLinkText, false);
  } else {
    navigateToFallback(fallback, "", true);
  }
}

function handleFallbackForUninstalledApp(appstore, fallback, openDeepLinkText) {
  if (appstore != null) {
    navigateToFallback(appstore, openDeepLinkText, true);
  } else {
    navigateToFallback(fallback, "", true);
  }
}

function handleRedirectIfNeeded(
  deeplink,
  appstore,
  fallback,
  openDeepLinkText,
  hasAppInstalled
) {
  if (hasAppInstalled) {
    handleRedirectWithAppInstalled(
      deeplink,
      appstore,
      fallback,
      openDeepLinkText
    );
  } else {
    handleRedirectWithAppNotInstalled(
      null,
      appstore,
      fallback,
      openDeepLinkText
    );
  }
}

function handleRedirectWithAppNotInstalled(
  deeplink,
  appstore,
  fallback,
  openDeepLinkText
) {
  openAppButtonHidden(true);
  appStoreButtonHidden(false);
  handleFallbackForUninstalledApp(appstore, fallback, openDeepLinkText);
}

function handleRedirectWithAppInstalled(
  deeplink,
  appstore,
  fallback,
  openDeepLinkText
) {
  var isBlurred = false;
  var didFallback = false;

  window.addEventListener("blur", function () {
    isBlurred = true;
  });

  window.addEventListener("focus", function () {
    isBlurred = false;
    doFallback();
  });

  function doFallback() {
    if (didFallback) {
      return;
    }

    if (document.webkitHidden || document.hidden || document.msHidden) {
      // No need to do anything
      openAppButtonHidden(false);
      return;
    }

    const currentLocation = window.top.location.href;
    if (isBlurred || didFallback || currentLocation === deeplink) {
      openAppButtonHidden(false);
      return;
    }

    didFallback = true;
    if (appstore != null) {
      appStoreButtonHidden(false);
    } else {
      appStoreButtonHidden(true);
    }

    handleFallback(appstore, fallback, openDeepLinkText);
  }
  window.location = deeplink;
  // The link is already properly configured, should be an universal link
  setTimeout(function () {
    doFallback();
  }, 250);
}
