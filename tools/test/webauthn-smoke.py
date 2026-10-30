#!/usr/bin/env python3
"""D-103 by hand, in a real Chrome with a virtual authenticator: the whole chain of security keys against a running core and UI.
  tools/test/webauthn-smoke.py <core log with the first-start line of admin> <core url> <ui url>
Needs `google-chrome` and the Python package `websocket-client`. The core must run with CINIM_WEBAUTHN_RP_ID=localhost and CINIM_WEBAUTHN_ORIGINS=<the UI origin, http://localhost:<port>>, the UI must be
reached as `localhost` (a key is made for the site name, so 127.0.0.1 would not do), and the core must be new (the script changes the password of `admin` the first time and then adds, uses and removes a key).
It checks: the plain login, adding a key on /ui/mfa with the recovery codes shown once, the second step of the login with the key, the counter, the API (`mfa_required` with a ticket and options, a ticket
that runs out of tries and is spent, a recovery code through the ticket, the list, the removal) and that two-step is off after the last key. Exit code 1 when something failed.
"""
import json, re, subprocess, time, urllib.request, sys, os, websocket

import tempfile
if len(sys.argv) != 4:
    sys.exit(__doc__)
S = tempfile.mkdtemp(prefix="webauthn-smoke-")
core = sys.argv[2].rstrip("/")
ui = sys.argv[3].rstrip("/")
log = open(sys.argv[1]).read()
pw = re.search(r"user=admin role=admin password=(\S+)", log).group(1)
NEWPW = "a-new-long-password-for-smoke-1"

def api(method, path, body=None, token=None):
    req = urllib.request.Request(core + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json", **({"Authorization": "Bearer " + token} if token else {})})
    try:
        r = urllib.request.urlopen(req)
        return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")

# the administrator changes the first password (until then nothing is allowed)
st, j = api("POST", "/api/v1/login", {"user": "admin", "password": pw})
if st == 200:
    api("PUT", "/api/v1/users/admin/password", {"current_password": pw, "password": NEWPW}, j["token"])
st, j = api("POST", "/api/v1/login", {"user": "admin", "password": NEWPW})
print("login after change:", st)

chrome = subprocess.Popen(["google-chrome", "--headless=new", "--no-sandbox", "--remote-debugging-port=29333", "--user-data-dir=" + S + "/profile", "--window-size=1000,800", "about:blank"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
time.sleep(3)
tabs = json.loads(urllib.request.urlopen("http://127.0.0.1:29333/json").read())
page = [t for t in tabs if t["type"] == "page"][0]
ws = websocket.create_connection(page["webSocketDebuggerUrl"])
mid = 0
def cdp(method, **params):
    global mid
    mid += 1
    ws.send(json.dumps({"id": mid, "method": method, "params": params}))
    while True:
        m = json.loads(ws.recv())
        if m.get("id") == mid:
            if "error" in m: raise Exception(m["error"])
            return m.get("result", {})
def ev(js):
    r = cdp("Runtime.evaluate", expression=js, returnByValue=True, awaitPromise=True)
    return r.get("result", {}).get("value")
def go(url):
    cdp("Page.navigate", url=url)
    time.sleep(1.5)
def waitfor(js, secs=8):
    t = time.time()
    while time.time() - t < secs:
        v = ev(js)
        if v: return v
        time.sleep(0.4)
    return None

cdp("Page.enable"); cdp("Runtime.enable"); cdp("WebAuthn.enable")
auth = cdp("WebAuthn.addVirtualAuthenticator", options={"protocol": "ctap2", "transport": "internal", "hasResidentKey": False, "hasUserVerification": True, "isUserVerified": True, "automaticPresenceSimulation": True})
print("virtual authenticator:", auth["authenticatorId"])

ok = True
def check(name, cond, extra=""):
    global ok
    print(("ok    " if cond else "FAIL  ") + name + (" " + str(extra) if not cond else ""))
    ok = ok and bool(cond)

# 1. a login with the password only: no second factor yet
go(ui + "/login")
ev("document.querySelector('[name=user]').value='admin'; document.querySelector('[name=password]').value=%s; document.querySelector('form.login').submit()" % json.dumps(NEWPW))
time.sleep(1.5)
check("plain login lands on the organisations", "/ui/orgs" in ev("location.href"), ev("location.href"))

# 2. add a key on the page of two-step login
go(ui + "/mfa")
check("the page offers to add a key", ev("!!document.querySelector('#add-key .webauthn-go')"))
ev("document.querySelector('#add-key [name=name]').value='virtual key'; document.querySelector('#add-key .webauthn-go').click()")
codes = waitfor("(document.querySelector('pre') && document.querySelector('pre').textContent) || null")
check("the key is registered and recovery codes are shown once", codes and len(codes.split()) == 10, codes)
go(ui + "/mfa")
body = ev("document.body.innerText")
check("the key is listed", "virtual key" in body and "Two-step login is on" in body, body[:300])
creds = cdp("WebAuthn.getCredentials", authenticatorId=auth["authenticatorId"])["credentials"]
check("the authenticator holds one credential", len(creds) == 1)

# 3. log out, log in again: the second step asks the key by itself
ev("document.querySelector('form.logout').submit()")
time.sleep(1.5)
go(ui + "/login")
ev("document.querySelector('[name=user]').value='admin'; document.querySelector('[name=password]').value=%s; document.querySelector('form.login').submit()" % json.dumps(NEWPW))
landed = waitfor("location.href.indexOf('/ui/orgs') >= 0 ? location.href : null", 12)
check("login with the key lands on the organisations", landed, ev("location.href + ' ' + document.body.innerText.slice(0,300)"))
creds = cdp("WebAuthn.getCredentials", authenticatorId=auth["authenticatorId"])["credentials"]
check("the counter moved on", creds and creds[0]["signCount"] >= 1, creds)

# 4. the API: a replayed ticket is spent, a wrong code is refused, a login without the key says mfa_required with ticket and options
ev("document.querySelector('form.logout').submit()")
st, j = api("POST", "/api/v1/login", {"user": "admin", "password": NEWPW})
check("API login says mfa_required with a ticket and key options", st == 401 and j.get("code") == "mfa_required" and j.get("mfa_ticket") and j.get("webauthn", {}).get("rpId") == "localhost", (st, j))
# 5. a recovery code logs in through the ticket
st, j = api("POST", "/api/v1/login", {"user": "admin", "password": NEWPW})
rc = codes.split()[0]
st, j2 = api("POST", "/api/v1/login", {"ticket": j["mfa_ticket"], "code": rc})
check("a recovery code logs in through the ticket", st == 200 and "token" in j2, (st, j2))
tok = j2.get("token")
st, j3 = api("GET", "/api/v1/me/mfa", None, tok)
check("GET /me/mfa lists the key", st == 200 and len(j3["keys"]) == 1 and j3["webauthn_available"] and not j3["totp"], j3)
st, j4 = api("POST", "/api/v1/login", {"ticket": j["mfa_ticket"], "code": codes.split()[1]})
check("the spent ticket is dead", st == 401, (st, j4))

st, jt = api("POST", "/api/v1/login", {"user": "admin", "password": NEWPW})
tk = jt.get("mfa_ticket", "x")
for i in range(5):
    st2, _ = api("POST", "/api/v1/login", {"ticket": tk, "code": "000000"})
st3, _ = api("POST", "/api/v1/login", {"ticket": tk, "code": "000000"})
check("a ticket is out of tries after five", st2 == 401 and st3 == 401)


# 6. remove the key with a recovery code: two-step is off again
kid = j3["keys"][0]["id"]
st, j5 = api("DELETE", "/api/v1/me/mfa/webauthn/" + kid, {"code": "AAAAA-AAAAA"}, tok)
check("removal with a wrong code is refused", st == 403, (st, j5))
st, j5 = api("DELETE", "/api/v1/me/mfa/webauthn/" + kid, {"code": codes.split()[2]}, tok)
check("removal with a recovery code works", st == 200 and j5["keys"] == [], (st, j5))
st, j6 = api("GET", "/api/v1/me/mfa", None, tok)
check("two-step is off after the last key", st == 200 and not j6["enabled"] and j6["recovery_codes_left"] == 0, j6)

cdp("WebAuthn.disable")
import signal, shutil
os.killpg(chrome.pid, signal.SIGTERM)
chrome.wait()
time.sleep(1)
shutil.rmtree(S, ignore_errors=True)
print("ALL OK" if ok else "SOME FAILED")
sys.exit(0 if ok else 1)
