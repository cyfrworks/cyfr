# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The source development stack as compose resolves docker-compose.dev.yml
over docker-compose.yml, held to the shipped file and kept apart from what
the checks on a host use.

  python3 -I compose_shape.py shape BASE_JSON DEV_JSON CHECKOUT PROJECT IMAGE
      The stack's services (Locus and its guard) and network against the
      same services resolved
      from docker-compose.yml alone: every field the shipped one's but the
      ones the dev stack names, and those as it names them, under the
      project PROJECT and on the image IMAGE.

  python3 -I compose_shape.py apart SHIPPED_JSON SOURCES DEV_JSON...
      Each slot's stack (one DEV_JSON a slot) against what the checks
      reserve, read from their sources under SOURCES: the test suite's
      listeners (config/test.exs) and the HSTS proof's, the shipped
      networks' subnets (SHIPPED_JSON, docker-compose.yml resolved with
      every profile), Docker's default address pools, and every name
      tests/, scripts/ and .github/ use outside the dev stack's own files;
      and against every other slot's ports and subnets.

  python3 -I compose_shape.py settings DEV_JSON
      The settings a mix boot beside the stack runs with, one NAME=VALUE
      a line, derived as the stack's documentation says.

Each check exits 1 naming every difference, 0 printing nothing.
"""
import copy
import ipaddress
import json
import os
import re
import sys

# The prefix of every name the loop gives, whatever the worktree's seed.
NAME_PREFIX = "cyfr-dev-"
# The seccomp profiles by the name the scaffold ships each under beside
# docker-compose.yml, at the path a checkout tracks it.
PROFILES = {
    "keeper.seccomp.json": "apps/locus/keeper/seccomp/keeper.json",
    "container.seccomp.json": "apps/locus/keeper/seccomp/container.json",
}
LOCUS = "locus"
GUARD = "locus-guard"
NETWORK = "locus"
SERVICES = [LOCUS, GUARD]
NETWORKS = [NETWORK]
# The runtime's port, which the guard publishes, and the backends', where
# the mix boot reaches the backends and builds beside them.
RUNTIME_TARGET = 4200
BACKENDS_PORT = "4101"

# Where each check reserves a port: a default, an assignment or a listener.
PORT_SOURCES = [
    "config/test.exs",
    "tests/proxy-hsts/run.sh",
]
PORT = re.compile(r"(?:_PORT(?::-|=)|port:\s*|(?:127\.0\.0\.1|localhost):)(\d{2,5})\b")
# Docker's default address pools, from which it draws every network a
# compose file gives no subnet.
DOCKER_POOLS = ["172.17.0.0/16", "172.18.0.0/15", "172.20.0.0/14", "172.24.0.0/13", "192.168.0.0/16"]
PRISM = "Prism's address (x-prism)"
PROXY = "Prism's proxy port (x-prism-proxy)"
RUNTIME_PORT = "the runtime's published port"
HOST_API_PORT = "the host API's port"
NAMED_IN = ["tests", "scripts", ".github"]
OWN_FILES = {"tests/dev-stack", "scripts/dev-stack.sh"}


def diff(path, have, want, out):
    if isinstance(have, dict) and isinstance(want, dict):
        for key in sorted(set(have) | set(want)):
            if key not in have:
                out.append(f"{path}.{key}: missing, want {json.dumps(want[key])}")
            elif key not in want:
                out.append(f"{path}.{key}: {json.dumps(have[key])} added")
            else:
                diff(f"{path}.{key}", have[key], want[key], out)
    elif have != want:
        out.append(f"{path}: {json.dumps(have)}, want {json.dumps(want)}")


def gateway(dev, network):
    return dev["networks"][network]["ipam"]["config"][0]["gateway"]


def expected_service(name, base, dev, project, image):
    want = copy.deepcopy(base)
    want["image"] = image
    want["pull_policy"] = "never"
    want["container_name"] = f"{project}-{name}"
    # Each service names its profile at its tracked path.
    if "security_opt" in base:
        want["security_opt"] = [
            f"seccomp=./{PROFILES.get(opt.removeprefix('seccomp=./'), opt)}" if opt.startswith("seccomp=") else opt
            for opt in base["security_opt"]
        ]
    url = dev["services"][LOCUS].get("environment", {}).get("LOCUS_RUNTIME_HOST_API_URL", "")
    port = url.rsplit(":", 1)[-1]
    port = port if port.isdigit() else "<port>"
    if name == LOCUS:
        want["environment"] = dict(
            base["environment"],
            LOCUS_RUNTIME_SERVICE_ID="wrk_local",
            LOCUS_RUNTIME_HOST_API_URL=f"http://{gateway(dev, NETWORK)}:{port}",
        )
    if name == GUARD:
        have = dev["services"][name]
        published = have.get("ports", [{}])[0].get("published")
        address = have.get("networks", {}).get(NETWORK, {}).get("ipv4_address")
        want["environment"] = dict(
            base["environment"],
            CYFR_GUARD_CONTROL_PLANE=gateway(dev, NETWORK),
            CYFR_GUARD_HOST_API=f"{gateway(dev, NETWORK)}:{port}",
        )
        want["networks"][NETWORK] = dict(base["networks"][NETWORK], ipv4_address=address)
        want["ports"] = [
            {"mode": "ingress", "host_ip": "127.0.0.1", "target": RUNTIME_TARGET, "published": published, "protocol": "tcp"}
        ]
    return want


def expected_network(name, base, dev, project):
    want = copy.deepcopy(base)
    want["name"] = f"{project}_{name}"
    want["ipam"] = {"config": dev["networks"][name].get("ipam", {}).get("config")}
    return want


def shape(base_path, dev_path, checkout, project, image):
    base = json.load(open(base_path))
    dev = json.load(open(dev_path))
    errors = []
    if dev.get("name") != project:
        errors.append(f"name: {json.dumps(dev.get('name'))}, want {json.dumps(project)}")
    if sorted(dev.get("services", {})) != sorted(SERVICES):
        errors.append(f"services: {sorted(dev.get('services', {}))}, want {sorted(SERVICES)}")
    if sorted(dev.get("networks", {})) != sorted(NETWORKS):
        errors.append(f"networks: {sorted(dev.get('networks', {}))}, want {sorted(NETWORKS)}")
    if errors:
        return errors
    for name in SERVICES:
        want = expected_service(name, base["services"][name], dev, project, image)
        diff(f"services.{name}", dev["services"][name], want, errors)
    for name in NETWORKS:
        diff(f"networks.{name}", dev["networks"][name], expected_network(name, base["networks"][name], dev, project), errors)
    # The profile each service names is the checkout's, the one the scaffold
    # ships beside docker-compose.yml.
    for name in SERVICES:
        for opt in dev["services"][name].get("security_opt", []):
            if opt.startswith("seccomp=") and not os.path.isfile(os.path.join(checkout, opt.removeprefix("seccomp="))):
                errors.append(f"{name}: {opt}: no such file in the checkout")
    return errors


def declared(dev):
    """The stack's host ports, subnets and fixed addresses, by what they are for."""
    url = dev["services"][LOCUS]["environment"]["LOCUS_RUNTIME_HOST_API_URL"]
    guard = dev["services"][GUARD]
    prism = dev.get("x-prism", "")
    ports = {
        PRISM: prism.rsplit(":", 1)[-1],
        PROXY: str(dev.get("x-prism-proxy", "")),
        RUNTIME_PORT: guard["ports"][0]["published"],
        HOST_API_PORT: url.rsplit(":", 1)[-1],
    }
    networks = {name: dev["networks"][name]["ipam"]["config"][0] for name in NETWORKS}
    addresses = {NETWORK: guard["networks"][NETWORK]["ipv4_address"]}
    return prism, ports, networks, addresses


def reserved_ports(sources):
    ports, errors = {}, []
    for path in PORT_SOURCES:
        try:
            found = set(PORT.findall(open(os.path.join(sources, path)).read()))
        except OSError as error:
            errors.append(f"{path}: {error.strerror}")
            continue
        if not found:
            errors.append(f"{path}: no port found where a check reserves one; teach compose_shape.py its new form")
        for port in found:
            ports.setdefault(port, []).append(path)
    return ports, errors


def shipped_subnets(shipped):
    return {
        f"docker-compose.yml network {name}": c["subnet"]
        for name, network in shipped.get("networks", {}).items()
        for c in (network.get("ipam") or {}).get("config") or []
        if c.get("subnet")
    }


def named_elsewhere(sources, names):
    """Every file under tests/, scripts/ and .github/ outside the dev
    stack's own that names a word beginning with one of names."""
    pattern = re.compile(r"(?<![\w.-])((?:" + "|".join(re.escape(n) for n in names) + r")[\w.-]*)")
    hits = []
    for top in NAMED_IN:
        for directory, _dirs, files in os.walk(os.path.join(sources, top)):
            for file in files:
                path = os.path.join(directory, file)
                relative = os.path.relpath(path, sources)
                if any(relative == own or relative.startswith(own + "/") for own in OWN_FILES):
                    continue
                try:
                    text = open(path, encoding="utf-8").read()
                except (OSError, UnicodeDecodeError):
                    continue
                for match in sorted(set(pattern.findall(text))):
                    hits.append(f"{relative} names {match}")
    return hits


def apart(shipped_path, sources, *dev_paths):
    shipped = json.load(open(shipped_path))
    errors = []
    reserved, unread = reserved_ports(sources)
    errors += unread
    seen = {}
    taken = shipped_subnets(shipped) | {f"Docker's default pool {p}": p for p in DOCKER_POOLS}
    names = []
    for path in dev_paths:
        dev = json.load(open(path))
        # Each slot's resolution is the file slot-<k>.json.
        slot = os.path.basename(path).removeprefix("slot-").removesuffix(".json")
        prism, ports, networks, addresses = declared(dev)
        if not re.fullmatch(r"127\.0\.0\.1:\d+", prism):
            errors.append(f"slot {slot}: x-prism is {json.dumps(prism)}, not 127.0.0.1:<port>")
        for what, port in ports.items():
            if not port.isdigit() or not 1024 <= int(port) <= 65535:
                errors.append(f"slot {slot}: {what} is {port}, not a port from 1024 to 65535")
            for source in reserved.get(port, []):
                errors.append(f"slot {slot}: {what} is {port}, which {source} reserves")
            if port in seen:
                errors.append(f"slot {slot}: {what} is {port}, as {seen[port]} is")
            seen[port] = f"slot {slot}'s {what}"
        for name, config in networks.items():
            subnet = ipaddress.ip_network(config["subnet"])
            for what, other in taken.items():
                if subnet.overlaps(ipaddress.ip_network(other)):
                    errors.append(f"slot {slot}: network {name}'s subnet {subnet} overlaps {what}")
            taken[f"slot {slot}'s network {name}"] = str(subnet)
            ip_range = ipaddress.ip_network(config["ip_range"])
            gw = ipaddress.ip_address(config["gateway"])
            if not ip_range.subnet_of(subnet):
                errors.append(f"slot {slot}: network {name}'s ip_range {ip_range} is not within {subnet}")
            if gw not in subnet or gw in ip_range:
                errors.append(f"slot {slot}: network {name}'s gateway {gw} is not in {subnet} outside its ip_range")
            if name in addresses:
                address = ipaddress.ip_address(addresses[name])
                if address not in subnet or address in ip_range or address == gw:
                    errors.append(f"slot {slot}: {GUARD}'s address {address} is not a free fixed address of {subnet}")
        names += [dev["name"]] + [s["container_name"] for s in dev["services"].values()]
        names += [n["name"] for n in dev["networks"].values()]

    shipped_names = {s.get("container_name") for s in shipped["services"].values()}
    for name in sorted(set(names)):
        if not name.startswith(NAME_PREFIX):
            errors.append(f"{name} is not named {NAME_PREFIX}<seed>")
        if name in shipped_names:
            errors.append(f"{name} is docker-compose.yml's own")
    errors += named_elsewhere(sources, [NAME_PREFIX])
    return errors


def settings(dev_path):
    dev = json.load(open(dev_path))
    _prism, ports, _networks, addresses = declared(dev)
    environment = dev["services"][LOCUS]["environment"]
    bind = environment["LOCUS_RUNTIME_HOST_API_URL"].split("//", 1)[1].rsplit(":", 1)[0]
    lines = [
        f"CYFR_PORT={ports[PRISM]}",
        f"CYFR_PROXY_PORT={ports[PROXY]}",
        f"CYFR_LOCUS_RUNTIME_WORKERS={environment['LOCUS_RUNTIME_SERVICE_ID']}"
        f"=http://127.0.0.1:{ports[RUNTIME_PORT]}",
        f"CYFR_HOST_API_BIND={bind}",
        f"CYFR_HOST_API_PORT={ports[HOST_API_PORT]}",
        f"CYFR_LOCUS_BACKENDS_URL=http://{addresses[NETWORK]}:{BACKENDS_PORT}",
        f"CYFR_PRIVATE_EGRESS_TARGETS={addresses[NETWORK]}",
    ]
    print("\n".join(lines))
    return []


def main(command, *args):
    errors = {"shape": shape, "apart": apart, "settings": settings}[command](*args)
    for line in errors:
        print(line)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
