function configureOpenView(
  title,
  image,
  deeplink,
  appstore,
  fallback,
  openInAppstoreText,
  hasAppInstalled,
  openAppIfInstalled,
  showPreview
) {
  if (showPreview) {
    handleShowPreviewPage(
      title,
      image,
      deeplink,
      appstore,
      fallback,
      openInAppstoreText,
      hasAppInstalled,
      openAppIfInstalled
    );
  } else {
    handleAutoRedirects(
      title,
      image,
      deeplink,
      appstore,
      fallback,
      openInAppstoreText,
      hasAppInstalled,
      openAppIfInstalled
    );
  }
}

function handleShowPreviewPage(
  title,
  image,
  deeplink,
  appstore,
  fallback,
  openInAppstoreText,
  hasAppInstalled,
  openAppIfInstalled
) {
  // Here i should navigate to appstore // fallback whatever that might be
  var linkToRedirectToInCaseAppNotOpen = null;

  if (isValidString(fallback)) {
    linkToRedirectToInCaseAppNotOpen = fallback;
  }

  if (
    isValidString(appstore) &&
    (openAppIfInstalled === true || openAppIfInstalled === null)
  ) {
    linkToRedirectToInCaseAppNotOpen = appstore;
  }

  var newLink = linkToRedirectToInCaseAppNotOpen;
  if (openAppIfInstalled === true || openAppIfInstalled === null) {
    newLink = appendRedirectParam(linkToRedirectToInCaseAppNotOpen);
  }

  setPreviewAppData(title, image, "Open", newLink);

  appStoreButtonHidden(true);
  openAppButtonHidden(false);
}

function handleAutoRedirects(
  title,
  image,
  deeplink,
  appstore,
  fallback,
  openInAppstoreText,
  hasAppInstalled,
  openAppIfInstalled
) {
  if (deeplink === null && appstore === null && !openAppIfInstalled) {
    // Do directly the redirect
    navigateToFallback(fallback, "", true);
    return;
  }

  if (deeplink === null && appstore === null && openAppIfInstalled) {
    let newLink = appendRedirectParam(fallback);

    setOpenAppUIData(title, image, "Open", newLink, null, null);
    openAppButtonHidden(false);
    appStoreButtonHidden(true);

    handleRedirectIfNeeded(
      deeplink,
      appstore,
      fallback,
      openInAppstoreText,
      hasAppInstalled
    );
    return;
  }

  setOpenAppUIData(
    title,
    image,
    "Open the app",
    deeplink,
    openInAppstoreText,
    appstore
  );

  appStoreButtonHidden(false);
  openAppButtonHidden(false);
  handleRedirectIfNeeded(
    deeplink,
    appstore,
    fallback,
    openInAppstoreText,
    hasAppInstalled
  );
}

function setOpenAppUIData(
  name,
  image,
  button_title,
  button_url,
  appstore_button_title,
  appstore_url
) {
  if (name == null || image == null) {
    setOpenViewHidden(true);
    setDownloadViewHidden(true);
    return;
  }

  function buttonOnClick() {
    goToLink(button_url, true);
  }

  function openAppStoreOnClick() {
    goToLink(appstore_url, true);
  }

  const buttonElement = document.getElementById("open-app-button");
  if (buttonElement) {
    buttonElement.onclick = buttonOnClick;
  }

  const appstoreButton = document.getElementById("open-appstore-button");
  if (appstoreButton) {
    appstoreButton.onclick = openAppStoreOnClick;
  }

  const imgElement = document.getElementById("app-logo");
  if (imgElement) {
    imgElement.src = image;
  }

  const titleElement = document.getElementById("app-name");
  if (titleElement) {
    titleElement.innerText = name;
  }

  setOpenAppButtonTitle(button_title);
  setOpenAppStoreButtonTitle(appstore_button_title);

  setOpenViewHidden(false);
  setDownloadViewHidden(true);
}

function setPreviewAppData(name, image, button_title, button_url) {
  if (name == null || image == null) {
    setOpenViewHidden(true);
    setDownloadViewHidden(true);
    return;
  }

  function buttonOnClick() {
    goToLink(button_url);
  }

  const buttonElement = document.getElementById("open-app-button");
  if (buttonElement) {
    buttonElement.onclick = buttonOnClick;
  }

  const imgElement = document.getElementById("app-logo");
  if (imgElement) {
    imgElement.src = image;
  }

  const titleElement = document.getElementById("app-name");
  if (titleElement) {
    titleElement.innerText = name;
  }

  setOpenAppButtonTitle(button_title);

  setOpenViewHidden(false);
  setDownloadViewHidden(true);
}

function setOpenAppButtonTitle(title) {
  const buttonElement = document.getElementById("open-app-button");
  if (buttonElement) {
    buttonElement.innerText = title;
  }
}

function setOpenAppStoreButtonTitle(title) {
  const appstoreButton = document.getElementById("open-appstore-button");
  if (appstoreButton) {
    appstoreButton.innerText = title;
  }
}

function appStoreButtonHidden(hidden) {
  const appstoreButton = document.getElementById("open-appstore-button");
  setElementHidden(appstoreButton, hidden);
}

function openAppButtonHidden(hidden) {
  const buttonElement = document.getElementById("open-app-button");
  setElementHidden(buttonElement, hidden);
}

function setOpenViewHidden(hidden) {
  const buttonElement = document.getElementById("mobile-view");
  setElementHidden(buttonElement, hidden);
}

function setDownloadViewHidden(hidden) {
  const buttonElement = document.getElementById("desktop-view");
  setElementHidden(buttonElement, hidden);
}

function setElementHidden(element, hidden) {
  if (element) {
    if (hidden == true) {
      element.style.display = "none";
    } else {
      element.style.display = "block";
    }
  }
}

function setDesktopUIData(name, image, qr, android, ios) {
  function androidButtonClick() {
    goToLink(android);
  }

  function iOSButtonClick() {
    goToLink(ios);
  }

  const imgElement = document.getElementById("desktop-app-icon");
  if (imgElement) {
    imgElement.src = image;
  }

  const titleElement = document.getElementById("desktop-app-name");
  if (titleElement) {
    titleElement.innerText = name;
  }

  const qrElement = document.getElementById("desktop-qr-code");
  if (qrElement) {
    const imgElement = document.createElement("img");
    imgElement.src = `data:image/png;base64,${qr}`;
    imgElement.width = 150;
    imgElement.height = 150;

    qrElement.appendChild(imgElement);
  }

  const androidButton = document.getElementById("desktop-android-button");
  if (androidButton) {
    androidButton.onclick = androidButtonClick;

    if (android == null) {
      androidButton.style.display = "none";
    }
  }

  const iosButton = document.getElementById("desktop-ios-button");
  if (iosButton) {
    iosButton.onclick = iOSButtonClick;

    if (ios == null) {
      iosButton.style.display = "none";
    }
  }

  setOpenViewHidden(true);
  setDownloadViewHidden(false);

  if (ios == null && android == null) {
    // Hide the QR code
    const downloadElement = document.getElementById("download-column");
    downloadElement.style.display = "none";
  }
}
