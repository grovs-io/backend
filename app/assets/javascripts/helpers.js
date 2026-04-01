function mobileJSONData(key) {
  const jsonDataElement = document.getElementById("popup");
  const jsonDataString = jsonDataElement.getAttribute(key);
  if (jsonDataString == null || jsonDataString == "") {
    return null;
  }

  const jsonData = JSON.parse(jsonDataString);

  return jsonData;
}

function desktopJSONData(key) {
  const jsonDataElement = document.getElementById("desktop-view");
  const jsonDataString = jsonDataElement.getAttribute(key);
  if (jsonDataString == null || jsonDataString == "") {
    return null;
  }

  const jsonData = JSON.parse(jsonDataString);

  return jsonData;
}

function openAppButton() {
  const element = document.getElementById("open-app-button");

  return element;
}

function redirectIfQueryParamExists() {
  // Get the URL parameters from the current URL
  const urlParams = new URLSearchParams(window.location.search);

  // Check if the 'redirect' query parameter exists
  var redirectTo = urlParams.get("grovs_redirect");

  if (redirectTo) {
    // If 'redirect' param exists, redirect to that URL
    if (!/^[a-zA-Z][a-zA-Z\d+\-.]*:\/\//.test(redirectTo)) {
      // If no protocol is found, prepend http://
      redirectTo = "http://" + redirectTo;
    }

    window.location.href = redirectTo;
  }
}

function appendRedirectParam(givenLink) {
  // Get the current URL
  const currentUrl = window.location.href;

  // Check if the current URL already has query parameters
  const url = new URL(currentUrl);

  if (givenLink == null) {
    return currentUrl.toString();
  }
  // Append the 'redirect' query parameter with the given link
  url.searchParams.set("grovs_redirect", givenLink);

  // Get the modified URL with the appended 'redirect' parameter
  const modifiedUrl = url.toString();

  return modifiedUrl;
}

function isValidString(value) {
  return typeof value === "string" && value !== null && value.trim() !== "";
}

function goToLink(link, skipRedirectUrl = false) {
  try {
    const currentHost = window.location.hostname; // e.g. preview.example.com
    const targetHost = new URL(link, window.location.href).hostname;

    if (currentHost === targetHost && !skipRedirectUrl) {
      let newURL = createRedirectUrl(link);
      window.top.location = newURL;
      return;
    }

    window.top.location = makeLinkFollowlable(link);
  } catch (e) {
    console.error("Invalid URL:", e);
  }
}

function makeLinkFollowlable(link) {
  if (!/^[a-zA-Z][a-zA-Z\d+\-.]*:\/\//.test(link)) {
    // If no protocol is found, prepend http://
    link = "http://" + link;
  }

  return link;
}

function createRedirectUrl(link) {
  const baseUrl = window.PREVIEW_BASE_URL;

  // Create a URLSearchParams object to manage query parameters
  const params = new URLSearchParams();

  // Add the 'url' parameter (encoded) to the URLSearchParams
  params.set("url", link);

  // Append the query parameters to the base URL
  const redirectUrl = `${baseUrl}?${params.toString()}`;

  return redirectUrl;
}
