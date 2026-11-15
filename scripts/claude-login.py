#!/usr/bin/env python3
"""One-time Claude login for the Kindle dashboard's Claude usage tile.

Opens claude.ai in your browser (OAuth with PKCE, scope user:profile only: read your plan usage,
no chats, no inference) and saves koreader-dash's own tokens in the macOS Keychain item
"koreader-dash-claude-oauth". ai-usage.sh refreshes them from then on.
Claude Code's own login ("Claude Code-credentials") is never read or changed here.

    scripts/claude-login.py            log in (run it again any time the tile says 已过期 for a login reason)
    scripts/claude-login.py --logout   delete koreader-dash's Claude tokens
No token is ever printed.
"""
import base64, hashlib, http.server, json, os, re, secrets, select, subprocess, sys, threading, time, urllib.parse

SERVICE, ACCOUNT = "koreader-dash-claude-oauth", "oauth"
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
AUTHORIZE_URL = "https://claude.ai/oauth/authorize"
TOKEN_URL = "https://console.anthropic.com/v1/oauth/token"
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
PORTS = (1456, 1458)
TIMEOUT = 300


def user_agent():
    d = os.path.expanduser("~/.local/share/claude/versions")
    try:
        vs = [v for v in os.listdir(d) if re.fullmatch(r"\d+\.\d+\.\d+", v)]
        vs.sort(key=lambda v: tuple(map(int, v.split("."))))
        return "claude-code/" + (vs[-1] if vs else "2.1.0")
    except OSError:
        return "claude-code/2.1.0"


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def curl(args, stdin_text):
    # Secrets travel on stdin (JSON body or a curl config), never in process arguments.
    r = subprocess.run(["curl", "-s", "--max-time", "20", "-w", "\n%{http_code}"] + args,
                       input=stdin_text, capture_output=True, text=True)
    body, _, code = r.stdout.rpartition("\n")
    return code.strip(), body


def keychain_save(creds):
    value = base64.b64encode(json.dumps(creds).encode()).decode()
    cmd = 'add-generic-password -U -s %s -a %s -l "koreader-dash Claude usage login" -w %s\n' % (SERVICE, ACCOUNT, value)
    r = subprocess.run(["security", "-i"], input=cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("Couldn't save to the Keychain: " + r.stderr.strip())


def logout():
    r = subprocess.run(["security", "delete-generic-password", "-s", SERVICE, "-a", ACCOUNT], capture_output=True)
    print("Deleted koreader-dash's Claude login." if r.returncode == 0 else "No koreader-dash Claude login was saved.")


class Callback(http.server.BaseHTTPRequestHandler):
    result = None
    event = threading.Event()

    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if "code" not in q and "error" not in q:
            self.send_response(404); self.end_headers(); return
        Callback.result = {k: v[0] for k, v in q.items()}
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write("<h2>Done. You can close this tab and go back to Terminal.</h2>".encode())
        Callback.event.set()

    def log_message(self, *args):
        pass


def start_server():
    for port in PORTS:
        try:
            srv = http.server.HTTPServer(("127.0.0.1", port), Callback)
        except OSError:
            continue
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        return srv, port
    sys.exit("Ports 1456 and 1458 are both busy; close whatever uses them and try again.")


def parse_pasted(text):
    text = text.strip()
    if "?" in text:
        q = urllib.parse.parse_qs(urllib.parse.urlparse(text).query)
        return {k: v[0] for k, v in q.items()}
    if "#" in text:
        code, state = text.split("#", 1)
        return {"code": code, "state": state}
    return {"code": text} if text else {}


def main():
    if "--logout" in sys.argv:
        return logout()
    verifier = b64url(secrets.token_bytes(48))
    challenge = b64url(hashlib.sha256(verifier.encode()).digest())
    state = b64url(secrets.token_bytes(24))
    srv, port = start_server()
    redirect = "http://localhost:%d/callback" % port
    url = AUTHORIZE_URL + "?" + urllib.parse.urlencode({
        "response_type": "code", "client_id": CLIENT_ID, "redirect_uri": redirect,
        "scope": "user:profile", "code_challenge": challenge, "code_challenge_method": "S256", "state": state})
    print("Opening claude.ai in your browser. Sign in if asked, then click Authorize.")
    print("If the browser doesn't open, open this link yourself:\n  " + url)
    print("If the browser ends on a page that won't load, copy its whole address and paste it here, then press Return.")
    subprocess.run(["open", url])

    got, deadline = None, time.time() + TIMEOUT
    while time.time() < deadline and got is None:
        if Callback.event.wait(0.5):
            got = Callback.result
            break
        if select.select([sys.stdin], [], [], 0)[0]:
            line = sys.stdin.readline()
            if line.strip():
                got = parse_pasted(line)
    srv.shutdown()
    if not got:
        sys.exit("Timed out after 5 minutes; run it again.")
    if "error" in got:
        sys.exit("Claude said: " + got.get("error_description", got["error"]))
    if got.get("state", state) != state:
        sys.exit("That login didn't come from this run (state mismatch); run it again.")

    code, body = curl(["-X", "POST", TOKEN_URL, "-H", "Content-Type: application/json",
                       "-H", "User-Agent: " + user_agent(), "--data-binary", "@-"],
                      json.dumps({"grant_type": "authorization_code", "code": got["code"], "state": state,
                                  "redirect_uri": redirect, "client_id": CLIENT_ID, "code_verifier": verifier}))
    try:
        tok = json.loads(body)
    except ValueError:
        tok = {}
    if code != "200" or not tok.get("access_token"):
        sys.exit("Token exchange failed (HTTP %s): %s" % (code, (tok.get("error_description") or tok.get("error") or body)[:200]))
    creds = {"access_token": tok["access_token"], "refresh_token": tok.get("refresh_token", ""),
             "expires_at": int(time.time()) + int(tok.get("expires_in", 3600))}
    keychain_save(creds)
    print("Saved koreader-dash's Claude login in the Keychain (item koreader-dash-claude-oauth).")

    code, body = curl(["-K", "-", USAGE_URL, "-H", "anthropic-beta: oauth-2025-04-20",
                       "-H", "Accept: application/json", "-H", "User-Agent: " + user_agent()],
                      'header = "Authorization: Bearer %s"\n' % creds["access_token"])
    if code == "200":
        u = json.loads(body)
        print("Check: Claude usage is %s%% this week, %s%% in the 5-hour window."
              % ((u.get("seven_day") or {}).get("utilization"), (u.get("five_hour") or {}).get("utilization")))
    else:
        print("Saved, but the usage check returned HTTP %s; the next ai-usage run will try again." % code)


if __name__ == "__main__":
    main()
