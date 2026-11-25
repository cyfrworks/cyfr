#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""A person's machine boots from the image's programs, as the keeper makes them (plan V1).

Each run is `cyfr-locus guest-check` in a container with docker-compose.yml's
locus configuration (copied from the running service, as
harness.py's second instances are), given `--device /dev/kvm` and nothing
else beyond its role's own confinement, on a kept-homes volume and a
`guest` volume of the run's own:

- Without the device no machine boots, and no device is made.
- The first start under the image makes the image's programs' device in
  the guest volume, named by the image's digest, and removes a device of
  another image once its own is whole. Its time is printed: on a runner,
  whose disk has never read the image, it is the cold making.
- The VMM runs in a space the stage makes, as a spawn's: under the
  machine's uid, with no group but /dev/kvm's, no capability, no_new_privs
  and a seccomp filter, and a mount namespace with nothing of the kept
  homes, no other machine's folder and of the guest volume the device
  alone, beside its own folder and /dev/kvm.
- The guest's own guard, the image's cyfr-guard with NET_ADMIN alone, is
  ready before the guest's keeper says anything, and the keeper proves it at its
  boot. The machine answers the hello with its boot identity; the guest's
  keeper makes one space under a pool uid, with no route, IPv4 or IPv6, a
  read-only root, whose directories are the image's programs
  bound read only from the guest's squashfs root, which reads the same boot
  identity, is refused socket(AF_VSOCK) and io_uring_setup with EPERM by the
  keeper's own policy, exits 0 and is released (through the relay, which
  serves on the listeners the guest's first process made); the machine's end
  is the acknowledged one, and its group holds no process.
- The device holds the image's own files and the mount points as empty
  folders, and nothing of another filesystem: not the canary a sign-in left
  in the kept-homes volume, nor Docker's bound /etc/hosts, resolv.conf and
  hostname. A maker that crossed into other mounts fails here.
- A second start finds the device and makes none, and boots a new guest.
- Two first starts at once on a fresh volume: one makes the device, the
  other waits for it, and both boot from it.
- A session's churn of small objects, with the guest reporting free pages
  from order 0 and from the kernel's own order: the processor time of
  each, and what the VMM held at the session's release, are printed.

Prerequisites: harness.py's, and /dev/kvm on the host. Usage: tests/locus-backends-image/vm.py IMAGE
"""

import json
import os
import re
import secrets
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import KEPT_ROOT, POOL_FIRST, POOL_LAST, RELEASE, ROLE, Stack, expect, require_docker  # noqa: E402
import imagesuite  # noqa: E402
from imagesuite import PROJECT_PREFIX, run  # noqa: E402

KVM = "/dev/kvm"
# The machines' folder, the guest volume's mount point, as the role table names it.
GUEST_ROOT = ROLE["guest_root"]
BOOT_ID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
# The machines' folders, on the Locus container's run directory's tmpfs,
# and the uid a machine's VMM runs as (internal/vm's Root and MachineUID).
MACHINES = RELEASE["run_dir"] + "/machines"
MACHINE_UID = 30201
DEVICE = re.compile(r"^" + re.escape(GUEST_ROOT) + r"/[0-9a-f]{64}\.sqfs$")
# A session's churn: small objects made and dropped, freed in pieces
# smaller than the kernel's own reporting order, then a wait in which the
# guest reports what was freed.
CHURN = ("const t = Date.now(); for (let r = 0; r < 12; r++) { let a = []; "
         "for (let i = 0; i < 2000000; i++) a.push({ i, s: 'x' + i }); a = null; global.gc(); } "
         "console.log('work_ms', Date.now() - t); setTimeout(() => {}, 30000)")


def role_args(stack):
    """The service's own confinement, as `docker run` arguments: its capabilities, security options, read-only
    root, IPC, tmpfs mounts, memory and environment, without its volumes and binds, health probe, entrypoint or
    command."""
    args = stack.copied(stack.inspect(stack.container), control=False)
    args = args[:args.index("--entrypoint")]
    out = []
    i = 0
    while i < len(args):
        if args[i] in ("--mount", "--volume", "--health-cmd", "--health-interval"):
            i += 2
            continue
        out.append(args[i])
        i += 1
    return out


def guest_check(stack, image, kept, guest, kvm=True, extra=()):
    """One `cyfr-locus guest-check` run: its exit, its report and its standard error."""
    args = ["docker", "run", "--rm", "--network", "none", *role_args(stack),
            "--mount", f"type=volume,source={kept},target={KEPT_ROOT}",
            "--mount", f"type=volume,source={guest},target={GUEST_ROOT}"]
    if kvm:
        args += ["--device", KVM]
    args += ["--entrypoint", "cyfr-locus", image, "guest-check", *extra]
    result = run(*args, check=False, timeout=600)
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    report = json.loads(lines[-1]) if lines else {}
    return result.returncode, report, result.stderr


def volume_files(image, volume):
    return run("docker", "run", "--rm", "--network", "none", "--mount", f"type=volume,source={volume},target=/v",
               "--entrypoint", "sh", image, "-c", "ls -A /v").stdout.split()


def listing(image, volume, device):
    """Every path the device holds, from the image's own unsquashfs."""
    name = os.path.basename(device)
    out = run("docker", "run", "--rm", "--network", "none", "--mount",
              f"type=volume,source={volume},target=/v,readonly", "--entrypoint", "unsquashfs", image,
              "-l", "-d", "", f"/v/{name}").stdout
    return {line.strip() for line in out.splitlines() if line.startswith("/")}


def kvm_gid():
    return os.stat(KVM).st_gid


def guest_lines(stderr):
    """The guest's console as the check kept it, without its mark."""
    return [line[len("guest: "):] for line in stderr.splitlines() if line.startswith("guest: ")]


def vmm_confined(report, what):
    vmm = report.get("vmm") or {}
    expect(not vmm.get("error"), f"{what}: the VMM's process is read from the host", vmm)
    uid, gid = str(MACHINE_UID), str(kvm_gid())
    expect(vmm.get("uid") == " ".join([uid] * 4), f"{what}: the VMM runs as the machine's uid alone", vmm)
    expect(vmm.get("gid") == " ".join([gid] * 4) and vmm.get("groups") == "",
           f"{what}: the VMM's one group is /dev/kvm's", vmm)
    expect(vmm.get("no_new_privs") == "1" and vmm.get("seccomp") == "2", f"{what}: the VMM runs under no_new_privs and a filter", vmm)
    expect(int(vmm.get("cap_eff", "1"), 16) == 0 and int(vmm.get("cap_bnd", "1"), 16) == 0,
           f"{what}: the VMM holds no capability, its bounding set empty", vmm)
    mounts = vmm.get("mounts") or []
    points = [m.get("point", "") for m in mounts]
    expect(KVM in points, f"{what}: the VMM's space has /dev/kvm", points)
    homes = RELEASE["home_root"]
    expect(not any(p == KEPT_ROOT or p.startswith(KEPT_ROOT + "/") or p == homes or p.startswith(homes + "/") for p in points),
           f"{what}: the VMM's space holds nothing of the homes", points)
    guest = [p for p in points if p == GUEST_ROOT or p.startswith(GUEST_ROOT + "/")]
    expect(guest == [report.get("device")], f"{what}: of the guest volume the VMM's space holds its device alone", guest)
    machines = [p for p in points if p == MACHINES or p.startswith(MACHINES + "/")]
    expect(len(machines) == 1 and machines[0].startswith(f"{MACHINES}/{uid}-"),
           f"{what}: the VMM's space holds its own machine's folder and no other", machines)
    # What it may write: its folder, the space's own fresh mounts and /dev's
    # nodes, kvm among them. The image's directories, the device and the
    # rest are read only.
    own = set(machines) | {"/proc", "/tmp", "/var/tmp", "/run", "/dev", "/dev/pts", "/dev/shm"} | \
        {f"/dev/{node}" for node in ("null", "zero", "full", "random", "urandom", "tty", "kvm")}
    writable = sorted(m.get("point") for m in mounts if m.get("access") != "ro")
    expect(set(writable) <= own, f"{what}: nothing is writable in the VMM's space but its own", writable)
    expect(any(m.get("point") == "/usr" and m.get("access") == "ro" for m in mounts),
           f"{what}: the VMM's space shows the image's directories read only, as every space", mounts)


def booted(code, report, stderr, what):
    expect(code == 0 and not report.get("error"), f"{what}: guest-check passes", f"exit {code}: {report}\n{stderr[-4000:]}")
    expect(DEVICE.match(report.get("device", "")), f"{what}: the device is named by the image's digest", report)
    expect(BOOT_ID.match(report.get("boot_id", "")), f"{what}: the hello carries a boot identity", report)
    spawned = report.get("spawned") or {}
    expect(POOL_FIRST <= spawned.get("uid", 0) <= POOL_LAST, f"{what}: the space runs under a pool uid", spawned)
    out = report.get("stdout", "").splitlines()
    expect(len(out) > 2 and out[0] == str(spawned.get("uid")), f"{what}: the space's own uid is its pool uid", out[:2])
    expect(out[1] == report["boot_id"], f"{what}: the space reads the guest's boot identity", out[:2])
    expect(len(out) > 2 and out[2] == "routes 0 0", f"{what}: the space has no route, IPv4 or IPv6", out[2:3])
    expect(len(out) > 3 and out[3] == "outer vsock -1 1 io_uring -1 1",
           f"{what}: the space is refused socket(AF_VSOCK) and io_uring_setup with EPERM", out[3:4])
    console = guest_lines(stderr)
    ready = [i for i, line in enumerate(console) if line.startswith("[cyfr-guard] ready: every rule installed")]
    keeper = [i for i, line in enumerate(console) if line.startswith("[cyfr-locus]")]
    expect(ready and keeper and ready[0] < keeper[0],
           f"{what}: the guest's guard was ready before its keeper said anything", "\n".join(console[-40:]))
    mounts = {}
    for line in out[4:]:
        fields = line.split()
        if " - " in line and len(fields) > 5:
            after = line.split(" - ", 1)[1].split()
            mounts[fields[4]] = (after[0], fields[5])
    fstype, options = mounts.get("/", ("", ""))
    expect(options.split(",")[0] == "ro", f"{what}: the space's root is read only", mounts.get("/"))
    for path in ("/usr", "/etc", "/app"):
        fstype, options = mounts.get(path, ("", ""))
        expect(fstype == "squashfs" and options.split(",")[0] == "ro",
               f"{what}: the space's {path} is the image's programs, read only from the guest's root", mounts.get(path))
    expect((report.get("exited") or {}).get("code") == 0, f"{what}: the space exits 0", report.get("exited"))
    expect(report.get("released") is True, f"{what}: the guest's keeper releases the space", report)
    expect(report.get("end") == "acknowledged", f"{what}: the machine's end is the acknowledged one", report)
    expect(report.get("group_procs") == [], f"{what}: no process is left in the machine's group", report)
    vmm_confined(report, what)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: tests/locus-backends-image/vm.py IMAGE")
    image = sys.argv[1]
    require_docker()
    if not os.path.exists(KVM):
        sys.exit(f"FAIL: this host has no {KVM}: a person's machine needs KVM")
    project = f"{PROJECT_PREFIX}vm-{secrets.token_hex(3)}"
    stack = Stack(project, image)
    stack.up()
    volumes = [f"{project}-{name}" for name in ("kept", "guest", "guest2")]
    kept, guest, guest2 = volumes
    try:
        for volume in volumes:
            run("docker", "volume", "create", volume)
        canary = f"canary-{secrets.token_hex(8)}"
        run("docker", "run", "--rm", "--network", "none", "--mount", f"type=volume,source={kept},target=/k",
            "--entrypoint", "sh", image, "-c", f"echo {canary} > /k/{canary} && chmod 0600 /k/{canary}")
        old = "f" * 64 + ".sqfs"
        run("docker", "run", "--rm", "--network", "none", "--mount", f"type=volume,source={guest},target=/g",
            "--entrypoint", "sh", image, "-c", f"echo old > /g/{old}")

        code, report, stderr = guest_check(stack, image, kept, guest, kvm=False)
        expect(code != 0 and "no /dev/kvm" in report.get("error", ""), "without the device no machine boots", f"exit {code}: {report}\n{stderr[-3000:]}")
        expect(not any(f.endswith(".sqfs") and f != old for f in volume_files(image, guest)),
               "without the device no device is made", volume_files(image, guest))

        code, first, stderr = guest_check(stack, image, kept, guest)
        booted(code, first, stderr, "the first start")
        expect(first["device_made"] is True, "the first start makes the device", first)
        print(f"the first start made the device in {first['device_ms']} ms and was ready {first['ready_ms']} ms "
              f"after the boot", flush=True)
        files = volume_files(image, guest)
        expect(old not in files and os.path.basename(first["device"]) in files,
               "the other image's device is gone once this one is whole", files)

        paths = listing(image, guest, first["device"])
        for present in ("/usr/local/bin/cyfr-guest", "/usr/local/bin/cyfr-locus", "/usr/bin/mksquashfs",
                        "/etc/passwd", KEPT_ROOT, GUEST_ROOT, "/proc", "/sys", "/dev"):
            expect(present in paths, f"the device holds {present}", sorted(paths)[:20])
        for mount in (KEPT_ROOT, GUEST_ROOT, "/proc", "/sys", "/dev", RELEASE["run_dir"]):
            inside = sorted(p for p in paths if p.startswith(mount + "/"))
            expect(not inside, f"the device holds nothing under the mount point {mount}", inside[:10])
        expect(not any(canary in p for p in paths), "the device holds no canary of the kept homes' volume")
        for bound in ("/etc/hosts", "/etc/resolv.conf", "/etc/hostname"):
            expect(bound not in paths, f"the device holds no Docker-bound {bound}")

        code, second, stderr = guest_check(stack, image, kept, guest)
        booted(code, second, stderr, "the second start")
        expect(second["device_made"] is False and second["device"] == first["device"],
               "the second start finds the device and makes none", second)
        expect(second["boot_id"] != first["boot_id"], "the second start boots a new guest", second)

        import concurrent.futures
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            together = list(pool.map(lambda _: guest_check(stack, image, kept, guest2), range(2)))
        for code, report, stderr in together:
            booted(code, report, stderr, "a start of two at once")
        made = [report["device_made"] for _, report, _ in together]
        expect(sorted(made) == [False, True], "of two first starts at once one makes the device, the other waits", made)
        expect(together[0][1]["device"] == together[1][1]["device"], "both boot from the one device")
        print("of two first starts at once, the waiter waited "
              f"{[r['device_ms'] for _, r, _ in together if not r['device_made']][0]} ms", flush=True)

        for flag, name in (((), "from order 0"), (("--kernel-reporting",), "from the kernel's own order")):
            code, report, stderr = guest_check(stack, image, kept, guest,
                                               extra=(*flag, "--", "/usr/local/bin/node", "--expose-gc", "-e", CHURN))
            expect(code == 0 and (report.get("exited") or {}).get("code") == 0, f"the churn, reporting {name}, runs",
                   f"{report}\n{stderr[-2000:]}")
            print(f"the churn, reporting {name}: {report['cpu_usec'] // 1000} ms of the machine's processor time, "
                  f"{report['stdout'].strip()}, {report['held_bytes'] >> 20} MiB held at the release of "
                  f"{report['peak_bytes'] >> 20} at most", flush=True)
    finally:
        stack.down()
        for volume in volumes:
            run("docker", "volume", "rm", "--force", volume, check=False)
    print("PASS: a person's machine boots from the image's programs, as the keeper makes them")


if __name__ == "__main__":
    imagesuite.stop_on_signals()
    main()
