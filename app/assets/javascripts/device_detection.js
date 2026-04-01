// Device checkers
function isIphone() {
  return /iPhone|iPod/.test(navigator.userAgent) && !window.MSStream;
}

function isIpad() {
  return /iPad/.test(navigator.userAgent) && !window.MSStream;
}

function isMac() {
  return navigator.userAgent.indexOf("Mac") !== -1;
}

function isWindows() {
  return navigator.userAgent.indexOf("Windows") !== -1;
}

function isLinux() {
  return /Linux/i.test(navigator.userAgent);
}

function isAndroidTablet() {
  var isAndroid = /Android/i.test(navigator.userAgent);

  // Typical tablet screen sizes (adjust these as needed)
  var minWidthForTablet = 600; // Minimum width for tablet in pixels
  var minHeightForTablet = 600; // Minimum height for tablet in pixels

  // Check if the viewport dimensions are greater than or equal to the minimum tablet size
  return (
    isAndroid &&
    window.innerWidth >= minWidthForTablet &&
    window.innerHeight >= minHeightForTablet
  );
}

function isAndroidPhone() {
  // Check if the user agent contains "Android"
  var isAndroid = /Android/i.test(navigator.userAgent);

  // Typical phone screen sizes (adjust these as needed)
  var maxWidthForPhone = 1000; // Maximum width for phone in pixels
  var maxHeightForPhone = 1000; // Maximum height for phone in pixels

  // Check if it's Android and if the viewport dimensions are smaller than typical tablet sizes
  return (
    isAndroid &&
    (window.innerWidth <= maxWidthForPhone ||
      window.innerHeight <= maxHeightForPhone)
  );
}

function isMobileDevice() {
  // Check if the user agent contains keywords commonly found in mobile device user agents
  var isMobileAgent =
    /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(
      navigator.userAgent
    );

  // Check if the device supports touch events
  var isTouchDevice =
    "ontouchstart" in window ||
    navigator.maxTouchPoints > 0 ||
    navigator.msMaxTouchPoints > 0;

  // Return true if either the user agent indicates a mobile device or the device supports touch events
  return isMobileAgent || isTouchDevice;
}

function isOperatingSystemVersionGreaterThanOrEqualToTarget(
  userAgent,
  targetVersion
) {
  var osVersionMatch = /iPhone OS ([^ ]*)/i.exec(userAgent);
  if (osVersionMatch && osVersionMatch[1]) {
    try {
      var versionString = osVersionMatch[1].replace(/_/gi, ".");
      var versionParts = versionString.split(".");
      var majorVersion = parseFloat(versionParts[0] + "." + versionParts[1]);
      if (majorVersion >= targetVersion) {
        return true;
      }
    } catch (error) {
      return false;
    }
  }
  return false;
}

function isAtLeastSafari1230() {
  function isSafari(userAgent) {
    return !!/^((?!chrome|android|crios|fxios).)*safari/i.test(userAgent);
  }

  const userAgent = navigator.userAgent;
  const safari = isSafari(userAgent);

  if (safari) {
    return isOperatingSystemVersionGreaterThanOrEqualToTarget(userAgent, 12.3);
  }

  return false;
}
