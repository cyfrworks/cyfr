# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The source development stack's locus-runtime service, as compose resolves
docker-compose.yml with docker-compose.dev.yml over it, against the shipped
service as compose resolves docker-compose.yml alone: the whole resolved
service and its network compared, every field the shipped one's except the
ones the dev stack names.

  python3 -I compose_shape.py BASE_JSON DEV_JSON HOST_API_PORT CHECKOUT

Exits 1 naming every field that differs, 0 printing nothing.
"""
import copy
import json
import os
import sys

PROJECT = "cyfr-dev"
SERVICE = "locus-runtime"
NETWORK = "locus-runtime"
GATEWAY = "172.16.231.1"
PROFILE = "apps/locus/keeper/seccomp/keeper.json"


def expected_service(base, port):
    want = copy.deepcopy(base)
    want["image"] = "cyfr-locus:dev"
    want["pull_policy"] = "build"
    want["container_name"] = "cyfr-dev-locus-runtime"
    want["environment"] = dict(
        base["environment"],
        LOCUS_RUNTIME_SERVICE_ID="wrk_local",
        LOCUS_RUNTIME_HOST_API_URL=f"http://{GATEWAY}:{port}",
    )
    want["ports"] = [
        {"mode": "ingress", "host_ip": "127.0.0.1", "target": 4200, "published": "4200", "protocol": "tcp"}
    ]
    want["security_opt"] = [
        f"seccomp=./{PROFILE}" if opt.startswith("seccomp=") else opt for opt in base["security_opt"]
    ]
    return want


def expected_network(base):
    want = copy.deepcopy(base)
    want["name"] = f"{PROJECT}_{NETWORK}"
    want["ipam"]["config"] = [dict(c, gateway=GATEWAY) for c in base["ipam"]["config"]]
    return want


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


def main(base_path, dev_path, port, checkout):
    base = json.load(open(base_path))
    dev = json.load(open(dev_path))
    errors = []
    if dev.get("name") != PROJECT:
        errors.append(f"name: {json.dumps(dev.get('name'))}, want {json.dumps(PROJECT)}")
    if sorted(dev.get("services", {})) != [SERVICE]:
        errors.append(f"services: {sorted(dev.get('services', {}))}, want [{SERVICE!r}]")
    diff(
        f"services.{SERVICE}",
        dev["services"].get(SERVICE),
        expected_service(base["services"][SERVICE], port),
        errors,
    )
    diff(f"networks.{NETWORK}", dev["networks"].get(NETWORK), expected_network(base["networks"][NETWORK]), errors)
    # The profile the service names is the checkout's, the one the scaffold
    # ships as keeper.seccomp.json.
    named = [o for o in dev["services"].get(SERVICE, {}).get("security_opt", []) if o.startswith("seccomp=")]
    for opt in named:
        path = os.path.join(checkout, opt.removeprefix("seccomp="))
        if not os.path.isfile(path):
            errors.append(f"{opt}: no such file in the checkout")
    for line in errors:
        print(line)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
