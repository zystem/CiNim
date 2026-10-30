// D-103: security keys. The only script of the UI (the page's Content-Security-Policy allows scripts from this host and nothing inline). The core gives the options for the browser in the form of
// base64url strings; this turns them into buffers, asks the browser, and puts the answer back into a form that the server reads like any other form.
(function () {
  "use strict";
  function toBuf(text) {
    var s = text.replace(/-/g, "+").replace(/_/g, "/");
    while (s.length % 4) s += "=";
    var raw = atob(s), out = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
    return out.buffer;
  }
  function toText(buf) {
    var b = new Uint8Array(buf), s = "";
    for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }
  function say(box, text) {
    var el = box.querySelector(".webauthn-status");
    if (el) el.textContent = text;
  }
  function describe(e) {
    if (e && e.name === "NotAllowedError") return "The browser did not get the key (cancelled, timed out, or no such key here).";
    if (e && e.name === "InvalidStateError") return "That key is registered already.";
    return "The key did not answer: " + (e && e.message ? e.message : e);
  }
  function descriptors(list) {
    return (list || []).map(function (d) { return { type: d.type, id: toBuf(d.id) }; });
  }
  function ready() {
    return !!(window.PublicKeyCredential && navigator.credentials);
  }

  function login(box) {
    var form = box.closest("form"), go = box.querySelector(".webauthn-go"), opts;
    try { opts = JSON.parse(box.getAttribute("data-options")); } catch (e) { say(box, "The options for the key are not readable."); return; }
    function run() {
      if (!ready()) { say(box, "This browser has no support for security keys. Use a code."); return; }
      say(box, "Waiting for the key...");
      navigator.credentials.get({ publicKey: {
        challenge: toBuf(opts.challenge), rpId: opts.rpId, timeout: opts.timeout, userVerification: opts.userVerification,
        allowCredentials: descriptors(opts.allowCredentials)
      } }).then(function (c) {
        var r = c.response;
        form.elements.assertion.value = JSON.stringify({
          id: c.id, clientDataJSON: toText(r.clientDataJSON), authenticatorData: toText(r.authenticatorData), signature: toText(r.signature)
        });
        form.submit();
      }, function (e) { say(box, describe(e)); });
    }
    go.addEventListener("click", run);
    run();
  }

  function register(form) {
    var go = form.querySelector(".webauthn-go");
    go.addEventListener("click", function () {
      if (!ready()) { say(form, "This browser has no support for security keys."); return; }
      say(form, "Asking the server...");
      fetch(form.getAttribute("data-begin"), { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: "" })
        .then(function (r) { return r.json().then(function (j) { if (!r.ok) throw new Error(j.error || r.status); return j; }); })
        .then(function (j) {
          var o = j.publicKey;
          say(form, "Touch the key...");
          return navigator.credentials.create({ publicKey: {
            rp: o.rp, user: { id: toBuf(o.user.id), name: o.user.name, displayName: o.user.displayName }, challenge: toBuf(o.challenge),
            pubKeyCredParams: o.pubKeyCredParams, timeout: o.timeout, attestation: o.attestation, authenticatorSelection: o.authenticatorSelection,
            excludeCredentials: descriptors(o.excludeCredentials)
          } });
        })
        .then(function (c) {
          form.elements.id.value = c.id;
          form.elements.clientDataJSON.value = toText(c.response.clientDataJSON);
          form.elements.attestationObject.value = toText(c.response.attestationObject);
          form.submit();
        })
        .catch(function (e) { say(form, describe(e)); });
    });
  }

  document.querySelectorAll("[data-webauthn=login]").forEach(login);
  document.querySelectorAll("[data-webauthn=register]").forEach(register);
})();
