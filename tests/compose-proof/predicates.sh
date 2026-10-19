# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# shellcheck shell=bash
#
# The Compose proof's whole-object predicates, sourced by
# tests/compose-proof/run.sh and held to canned answers by
# tests/compose-proof/predicates-test.sh. Each compares the complete object
# a check is about with the complete object the case expects, every field
# exact or bound to an independent read, and on failure says on stdout
# what differs. ROOT is the checkout.

# The head, as the reach vectors spell one, that the project runs: `$1` the
# expected head (JSON: mode, host, port, public_url, acme_email,
# builds_url, node_id, profiles), `$2` .env, `$3` the cyfr container's
# environment (`docker inspect` .Config.Env as JSON), `$4` the project's
# running services, one line, sorted, `$5` the node id the tailnet state
# holds and `$6` the machine's name it holds (Self.DNSName, with the
# trailing dot), both read apart from .env (empty where no node runs; `$5`
# `-` where the state holds another node by design, as a mismatched start
# leaves it, which the case holds apart). Every reach setting .env and the
# running cyfr hold is the head's, a field the head lacks unset; the
# services running are cyfr and the proxy each of the head's profiles
# starts; a tailnet head's node id is the state's, and its host and public
# URL are the state's name without the dot and https:// that name, so a
# head expected from what .env holds is no head the machine has. The
# reach settings are the ones the reach vectors' derivations assign or
# remove, and the proof's mapping of them to head fields is held to that
# set.
head_holds() {
  python3 -I - "$ROOT/tests/fixtures/reach_modes.json" "$@" <<'PY'
import json, sys
vectors, want, env_path, container_env, running, state_id = sys.argv[1:7]
state_name = sys.argv[7] if len(sys.argv) > 7 else ""
FIELDS = {"mode": "CYFR_REACH", "host": "CYFR_HOST", "port": "CYFR_PORT", "public_url": "CYFR_PUBLIC_URL",
          "acme_email": "CADDY_ACME_EMAIL", "builds_url": "CYFR_LOCUS_BUILDS_URL", "node_id": "CYFR_TAILNET_NODE_ID"}
PROXIES = {"public": "caddy", "tailnet": "tailscale"}
problems = []
derived = set()
for v in json.load(open(vectors))["derive"]:
    derived |= set(v.get("assignments", {})) | set(v.get("removals", []))
if derived != set(FIELDS.values()):
    sys.exit(print(f"the reach vectors derive {sorted(derived)}, which the proof's head fields do not map: {sorted(FIELDS.values())}") or 1)
head = json.loads(want)
unknown = set(head) - set(FIELDS) - {"profiles"}
if unknown:
    sys.exit(print(f"the expected head has fields no reach setting holds: {sorted(unknown)}") or 1)
expected = {key: str(head[field]) for field, key in FIELDS.items() if head.get(field) not in (None, "")}
def dotenv(path):
    values = {}
    for line in open(path).read().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, _, value = line.partition("=")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        values[name.strip()] = value
    return values
held = {k: v for k, v in dotenv(env_path).items() if k in FIELDS.values() and v != ""}
if held != expected:
    problems.append(f".env holds the reach settings {json.dumps(held, sort_keys=True)}, not the head's {json.dumps(expected, sort_keys=True)}")
try:
    runs = dict(e.split("=", 1) for e in json.loads(container_env) or [])
except ValueError:
    runs = None
if runs is None:
    problems.append(f"cyfr's environment could not be read: {container_env[:200]!r}")
else:
    running_env = {k: v for k, v in runs.items() if k in FIELDS.values() and v != ""}
    if running_env != expected:
        problems.append(f"the running cyfr holds the reach settings {json.dumps(running_env, sort_keys=True)}, not the head's {json.dumps(expected, sort_keys=True)}")
profiles = head.get("profiles")
if not isinstance(profiles, list) or any(p not in PROXIES for p in profiles):
    problems.append(f"the head's profiles {profiles!r} are not the proxies' the proof knows ({sorted(PROXIES)})")
else:
    services = " ".join(sorted(["cyfr"] + [PROXIES[p] for p in profiles]))
    if running != services:
        problems.append(f"the project runs '{running}', not '{services}'")
if head.get("mode") == "tailnet" and state_id != "-":
    if state_id != head.get("node_id"):
        problems.append(f"the tailnet state holds the node {state_id or 'none'!r}, not the head's {head.get('node_id')!r}")
    if len(state_name) < 2 or not state_name.endswith("."):
        problems.append(f"the tailnet state's machine name {state_name!r} is no DNSName (a name with its trailing dot)")
    else:
        name = state_name[:-1]
        if (head.get("host"), head.get("public_url")) != (name, f"https://{name}"):
            problems.append(f"the head's host and public URL are {head.get('host')!r} and {head.get('public_url')!r}, not the tailnet state's {name!r} and 'https://{name}'")
for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY
}

# Serve's applied configuration `$1` (JSON) is exactly the engine's for the
# node `$2` forwarding to cyfr's proxy listener on `$3`: one TCP listener,
# 443, HTTPS, one web server, `$2`:443, with one handler, / proxied to
# http://cyfr:`$3`, and nothing else (no Funnel, no other listener or
# handler).
serve_config_holds() {
  python3 -I - "$@" <<'PY'
import json, sys
text, name, port = sys.argv[1:4]
want = {"TCP": {"443": {"HTTPS": True}}, "Web": {f"{name}:443": {"Handlers": {"/": {"Proxy": f"http://cyfr:{port}"}}}}}
try:
    got = json.loads(text)
except ValueError:
    sys.exit(print(f"Serve's configuration is not JSON: {text[:200]!r}") or 1)
if got != want:
    sys.exit(print(f"Serve's configuration is {json.dumps(got, sort_keys=True)}, not {json.dumps(want, sort_keys=True)}") or 1)
PY
}

# The preview the command line printed in `$1` (a log, its first line the
# command) for the switch from head `$2` to head `$3` (JSON): exactly the
# preview block, each of the four sentences of the words the reach vectors
# hold for those heads as old → new, a line for each change of a head
# field the four do not show (the tailnet machine, the port on this
# computer, the builds service; apps/codex/cmd/reach.go unwordedChanges),
# and, as the address changes, the
# engine's address-change steps (apps/codex/internal/reach/switch.go
# addressChanges) and the line on the CYFR identity; then one line, the
# command's refusal that it made no change: the complete sentence
# apps/codex/cmd/reach.go showUnconfirmed returns, as the command line
# prints an error ("Error: ", apps/codex/cmd/root.go).
preview_holds() {
  python3 -I - "$ROOT/tests/fixtures/reach_modes.json" "$ROOT/apps/codex/internal/reach/switch.go" \
    "$ROOT/apps/codex/cmd/reach.go" "$@" <<'PY'
import json, re, sys
vectors, switch_go, reach_go, log, old_text, new_text = sys.argv[1:7]
words = json.load(open(vectors))["words"]
def sentences(head):
    # The words of a head: the vectors' sentences for a head of the same
    # mode and email presence, with its own address.
    shaped = [w for w in words if w["head"]["mode"] == head["mode"] and bool(w["head"].get("acme_email")) == bool(head.get("acme_email"))]
    if not shaped:
        sys.exit(print(f"the reach vectors hold no words for a {head['mode']} head like {head}") or 1)
    who, _, email, ports = shaped[0]["sentences"]
    address = head["public_url"] if head["mode"] != "local" else f"http://localhost:{head['port']}"
    email = f"Certificate email: {head['acme_email']}" if head.get("acme_email") else email
    return [who, f"Address: {address}", email, ports]
old, new = json.loads(old_text), json.loads(new_text)
block = ["This changes how this home is reached:"]
for before, after in zip(sentences(old), sentences(new)):
    label, _, was = before.partition(": ")
    _, _, now = after.partition(": ")
    block.append(f"  {label}: {was} → {now}")
def machine(head):
    return f"{head['host']} ({head['node_id']})" if head.get("node_id") else "none"
def builds(head):
    return head.get("builds_url") or "off"
if old.get("node_id") != new.get("node_id"):
    block.append(f"  Tailnet machine: {machine(old)} → {machine(new)}")
if old["port"] != new["port"]:
    block.append(f"  Port on this computer: {old['port']} → {new['port']}")
if old.get("builds_url") != new.get("builds_url"):
    block.append(f"  Builds service: {builds(old)} → {builds(new)}")
source = open(switch_go).read()
listed = re.search(r"var addressChanges = \[\]string\{(.*?)\n\}", source, re.S)
if not listed:
    sys.exit(print("switch.go holds no addressChanges list") or 1)
changes = [json.loads(s) for s in re.findall(r'"(?:[^"\\]|\\.)*"', listed.group(1))]
if sentences(old)[1] != sentences(new)[1]:
    block.append("The address changes, so:")
    block += [f"  {i}. {c}" for i, c in enumerate(changes, 1)]
    block.append("Your CYFR identity does not change.")
GO_STRING = r'"(?:[^"\\]|\\.)*"'
unconfirmed = re.search(r"^func showUnconfirmed\(.*?^\}$", open(reach_go).read(), re.S | re.M)
again = unconfirmed and re.search(r"^\tconst again = (" + GO_STRING + r")$", unconfirmed.group(0), re.M)
shown = unconfirmed and re.search(r"^\tprintPreview\(out, p\)\n\treturn errors\.New\((" + GO_STRING + r") \+ again\)$", unconfirmed.group(0), re.M)
if not (again and shown):
    sys.exit(print("reach.go's showUnconfirmed holds no refusal after the preview to expect") or 1)
refusal = "Error: " + json.loads(shown.group(1)) + json.loads(again.group(1))
lines = open(log).read().splitlines()[1:]
if lines != block + [refusal]:
    sys.exit(print("the preview printed\n  " + "\n  ".join(lines) + "\nnot\n  " + "\n  ".join(block + [refusal])) or 1)
PY
}

# The home's answers at / without the session cookie, `$1`, and with the
# fixture person's, `$2` (`standin fetch` JSON), for the person whose
# athanor's route segment is `$3`: without it, 302 to /login; with it, 302
# to that athanor's chat (PrismWeb.ChatLive.chat_path, ?a=<segment>).
cookie_holds() {
  python3 -I - "$@" <<'PY'
import json, sys, urllib.parse
problems = []
def answer(text, what):
    try:
        value = json.loads(text)
    except ValueError:
        value = {}
    if not isinstance(value.get("status"), int):
        problems.append(f"{what}: no answer: {text[:200]!r}")
        return None, None
    return value["status"], (value.get("headers") or {}).get("Location")
unsigned, signed, segment = sys.argv[1:4]
want_unsigned = (302, ["/login"])
want_signed = (302, ["/chat?" + urllib.parse.urlencode({"a": segment})])
got = answer(unsigned, "without the cookie")
if got[0] is not None and got != want_unsigned:
    problems.append(f"without the cookie / answered {got}, not {want_unsigned}")
got = answer(signed, "with the cookie")
if got[0] is not None and got != want_signed:
    problems.append(f"with the person's cookie / answered {got}, not {want_signed}")
for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY
}

# Whether an anonymous request with the forged identity headers was refused
# exactly as the same request without them: `$1` and `$2` the two answers
# (`standin fetch` JSON, or curl's dump and STATUS= line from
# `from_network`). The class of a refusal is its status, the Location of a
# redirect, and the JSON-RPC error code of an MCP answer, which must be an
# error; an answer that is no refusal, or no answer at all, fails.
same_refusal() {
  python3 -I - "$@" <<'PY'
import json, re, sys
def refusal(text):
    text = text.replace("\r", "")
    try:
        value = json.loads([l for l in text.splitlines() if l.startswith("{")][-1])
    except (IndexError, ValueError):
        value = None
    if isinstance(value, dict) and isinstance(value.get("status"), int):
        status, headers, body = value["status"], value.get("headers") or {}, value.get("body") or ""
        location = (headers.get("Location") or [None])[0]
    else:
        statuses = re.findall(r"^STATUS=(\d{3})$", text, re.M)
        if not statuses:
            return None
        status = int(statuses[-1])
        head, _, body = text.partition("\n\n")
        location = next((l.split(":", 1)[1].strip() for l in head.splitlines() if l.lower().startswith("location:")), None)
    code = None
    for line in body.splitlines():
        if line.startswith("data:"):
            line = line[len("data:"):].strip()
        try:
            rpc = json.loads(line)
        except ValueError:
            continue
        if isinstance(rpc, dict) and "jsonrpc" in rpc:
            if "error" not in rpc:
                return ("no refusal", status, "result")
            code = rpc["error"].get("code")
    if status < 300 and code is None:
        return ("no refusal", status, None)
    return (status, location, code)
plain, forged = refusal(sys.argv[1]), refusal(sys.argv[2])
if plain is None or forged is None:
    sys.exit(print(f"a request got no answer: {sys.argv[1][:200]!r} / {sys.argv[2][:200]!r}") or 1)
if plain[0] == "no refusal" or forged[0] == "no refusal":
    sys.exit(print(f"an anonymous request was not refused: {plain} / {forged}") or 1)
if plain != forged:
    sys.exit(print(f"the forged identity headers changed the refusal from {plain} to {forged}") or 1)
PY
}

# The capability set and security options of a running proxy: `$1` the
# service, `$2` its container's `docker inspect` HostConfig (JSON), `$3`
# its process's /proc/1/status. caddy drops every capability and adds back
# NET_BIND_SERVICE alone, which its binary's file capability needs, and
# tailscale keeps none, each with no-new-privileges and nothing else; the
# effective set is exactly that.
capabilities_hold() {
  python3 -I - "$@" <<'PY'
import json, re, sys
service, host_config, proc_status = sys.argv[1:4]
CAPS = {"NET_BIND_SERVICE": 10}
WANT = {"caddy": (["ALL"], ["NET_BIND_SERVICE"]), "tailscale": (["ALL"], [])}
if service not in WANT:
    sys.exit(print(f"no capability set is expected of {service}") or 1)
drop, add = WANT[service]
try:
    config = json.loads(host_config)
except ValueError:
    sys.exit(print(f"{service}'s HostConfig could not be read") or 1)
norm = lambda caps: sorted(re.sub(r"^CAP_", "", c.upper()) for c in caps or [])
problems = []
if norm(config.get("CapDrop")) != drop:
    problems.append(f"{service} drops {norm(config.get('CapDrop'))}, not {drop}")
if norm(config.get("CapAdd")) != add:
    problems.append(f"{service} adds {norm(config.get('CapAdd'))}, not {add}")
if sorted(config.get("SecurityOpt") or []) != ["no-new-privileges:true"]:
    problems.append(f"{service}'s security options are {config.get('SecurityOpt')}, not [no-new-privileges:true]")
eff = re.search(r"^CapEff:\s*([0-9a-f]+)$", proc_status, re.M)
want_eff = sum(1 << CAPS[c] for c in add)
if not eff:
    problems.append(f"{service}'s process status names no CapEff")
elif int(eff.group(1), 16) != want_eff:
    problems.append(f"{service}'s effective capabilities are {eff.group(1)}, not {want_eff:016x}")
for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY
}
