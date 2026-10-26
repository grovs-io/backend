(function () {
  "use strict";
  var w = window;
  var d = document;
  var g = w.__grovs || {};
  var send = typeof g.post === "function" ? g.post : function () {};
  var seq = 0;
  var pending = {};
  var FIELD = /\{\{\s*(user|event)\.([A-Za-z0-9_]+)\s*(?:\|\s*default:\s*"([^"]*)"\s*)?\}\}/g;
  var FILLABLE = /^(alt|title|value|placeholder|aria-.+|data-(?!grovs-url$).+)$/;
  var has = Object.prototype.hasOwnProperty;
  var Observer = w.ResizeObserver;
  // Read through the getter taken now, before the page's own scripts could replace it.
  var activation = w.navigator.userActivation;
  var descriptor = activation && Object.getOwnPropertyDescriptor(Object.getPrototypeOf(activation), "isActive");
  // Bound now, so a page replacing Function.prototype.call later can't answer for it.
  var isActive = descriptor ? descriptor.get.bind(activation) : null;
  // A frame shown after a host click inherits that activation; a tap must happen in here.
  var now = Date.now;
  var tapped = -Infinity;
  ["pointerdown", "keydown", "click"].forEach(function (type) {
    w.addEventListener(type, function (e) {
      if (e.isTrusted) tapped = now();
    }, true);
  });
  Reflect.deleteProperty(w, "__grovs");
  // The boot script's text holds the token; gone before the page's own scripts can read it.
  if (d.currentScript) d.currentScript.remove();

  function copy(source) {
    return Object.freeze(Object.assign({}, source));
  }

  function post(type, args) {
    var id = String(++seq);
    send({ v: 1, token: g.token, id: id, type: type, args: args });
    return id;
  }

  function reply(message) {
    if (!message || message.v !== 1 || !has.call(pending, message.id)) return;
    var call = pending[message.id];
    delete pending[message.id];
    if (message.ok) call.resolve(message.result);
    else call.reject(new Error(message.error || "invalid"));
  }

  var user = copy(g.user);
  var event = copy(g.event);
  var api = Object.freeze({
    close: function () {
      post("close", {});
    },
    track: function (name, properties) {
      post("track", { name: name, properties: properties == null ? {} : properties });
    },
    open: function (url) {
      post("open", { url: url, active: now() - tapped < 2000 && (isActive ? isActive() : true) });
    },
    setAttribute: function (key, value) {
      post("setAttribute", { key: key, value: value });
    },
    requestPushPermission: function () {
      return new Promise(function (resolve, reject) {
        pending[post("requestPushPermission", {})] = { resolve: resolve, reject: reject };
      });
    },
    user: user,
    event: event,
    capabilities: copy(g.capabilities)
  });
  Object.defineProperty(w, "grovs", { value: api, enumerable: true });
  Object.defineProperty(w, "__grovsReply", { value: reply });
  w.addEventListener("message", function (e) {
    if (e.source === w.parent && e.source !== w) reply(e.data);
  });

  w.addEventListener("click", function (e) {
    var action, link;
    e.composedPath().forEach(function (node) {
      if (!node.matches) return;
      action = action || (node.matches("[data-grovs-action]") && node);
      link = link || (node.matches("a[href],area[href]") && node);
    });
    if (action) {
      var kind = action.getAttribute("data-grovs-action");
      if (kind === "close") api.close();
      else if (kind === "open") api.open(action.getAttribute("data-grovs-url"));
      else if (kind === "track") api.track(action.getAttribute("data-grovs-event"));
      else if (!link) return;
      e.preventDefault();
      return;
    }
    if (!link || e.defaultPrevented) return;
    var href = link.getAttribute("href");
    e.preventDefault();
    var hash = /^#(.*)/.exec(href.replace(/[\t\n\r]/g, "").replace(/^[\x00-\x20]+|[\x00-\x20]+$/g, ""));
    if (!hash) return api.open(href);
    // A srcdoc frame resolves "#x" against the host page's URL and would load that page.
    var id = hash[1];
    try {
      id = decodeURIComponent(id);
    } catch (x) {}
    var to = id && (d.getElementById(id) || d.querySelector('a[name="' + CSS.escape(id) + '"]'));
    if (to) to.scrollIntoView();
    else if (!id || id.toLowerCase() === "top") w.scrollTo(0, 0);
  });

  function plain(n) {
    var m = /^(-?)(\d+)(?:\.(\d+))?e([+-]\d+)$/.exec(String(n));
    if (!m) return String(n);
    var digits = m[2] + (m[3] || "");
    var point = m[2].length + Number(m[4]);
    if (point <= 0) return m[1] + "0." + new Array(1 - point).join("0") + digits;
    if (point >= digits.length) return m[1] + digits + new Array(point - digits.length + 1).join("0");
    return m[1] + digits.slice(0, point) + "." + digits.slice(point);
  }

  // The SDK engines' text form, so a value reads the same as in a native template.
  function text(value) {
    if (typeof value === "string") return value;
    if (typeof value === "boolean") return value ? "true" : "false";
    if (typeof value === "number" && isFinite(value)) return plain(value === 0 ? 0 : value);
    return null;
  }

  function lookup(source, key, fallback) {
    var from = source === "user" ? user : event;
    var value = has.call(from, key) ? text(from[key]) : null;
    return value === null || value === "" ? (fallback === undefined ? null : fallback) : value;
  }

  function personalize() {
    var found = [];
    var walker = d.createTreeWalker(d.documentElement, 4);
    for (var node; (node = walker.nextNode()); ) {
      if (!node.parentNode.closest("script,style,template,textarea")) found.push(node);
    }
    var elements = d.getElementsByTagName("*");
    for (var i = 0; i < elements.length; i++) {
      for (var j = 0, attrs = elements[i].attributes; j < attrs.length; j++) {
        if (FILLABLE.test(attrs[j].name.toLowerCase())) found.push(attrs[j]);
      }
    }
    var missing = false;
    found.forEach(function (place) {
      place.textContent.replace(FIELD, function (whole, source, key, fallback) {
        if (lookup(source, key, fallback) === null) missing = true;
        return whole;
      });
    });
    if (!missing) {
      found.forEach(function (place) {
        var filled = place.textContent.replace(FIELD, function (whole, source, key, fallback) {
          return lookup(source, key, fallback);
        });
        if (filled !== place.textContent) place.textContent = filled;
      });
    }
    post("ready", { missing: missing });
    measure();
  }

  var last = 0;
  var frame = 0;
  function measure() {
    frame = 0;
    // Ceil: a cut-off fraction would add a scrollbar.
    var height = Math.ceil(d.documentElement.getBoundingClientRect().height);
    if (height === last) return;
    last = height;
    post("height", { value: height });
  }
  // Hidden WebKit pages may run no frames: ready and load measure too.
  if (Observer) {
    new Observer(function () {
      frame = frame || requestAnimationFrame(measure);
    }).observe(d.documentElement);
  }
  w.addEventListener("load", measure);
  // The app resets its frame on rotation, so even an unchanged height is posted again.
  w.addEventListener("resize", function () {
    last = 0;
    frame = frame || requestAnimationFrame(measure);
  });
  if (d.readyState === "loading") d.addEventListener("DOMContentLoaded", personalize);
  else personalize();
})();
