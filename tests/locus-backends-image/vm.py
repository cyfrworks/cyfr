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
  machine's own uid, which is no pool's, with no group but /dev/kvm's, no
  capability, no_new_privs and a seccomp filter, and a mount namespace with
  nothing of the kept homes, no other machine's folder and of the guest
  volume the device alone, beside its own folder, the one the check names,
  and /dev/kvm; each mount it may write is the filesystem its place holds,
  and nothing else is writable.
- The guest's own guard, the image's `cyfr-locus guard-control` with NET_ADMIN alone, is
  ready before the guest's keeper says anything, and the keeper proves it at its
  boot. The machine answers the hello with its boot identity; the guest's
  keeper makes one space under a pool uid, with no route, IPv4 or IPv6, a
  read-only root, whose directories are the image's programs
  bound read only from the guest's squashfs root, which reads the same boot
  identity, is refused socket(AF_VSOCK) and io_uring_setup with EPERM by the
  keeper's own policy, exits 0, the exit its own spawn's, and is released
  (through the relay, which
  serves on the listeners the guest's first process made); the machine's end
  is the acknowledged one, and its group holds no process.
- The device holds the image's own files and the mount points as empty
  folders, and nothing of another filesystem: not the canary a sign-in left
  in the kept-homes volume, nor Docker's bound /etc/hostname; its
  /etc/hosts and resolv.conf are the guest's own, not Docker's. A maker that
  crossed into other mounts fails here.
- A second start finds the device and makes none, and boots a new guest,
  and a second machine beside it in the same keeper, under a uid of its
  own, ends acknowledged while the first goes on to answer for its space.
- The keeper killed while its container's PID namespace lives on leaves
  no VMM and no process of a machine's uid.
- Two first starts at once on a fresh volume: one makes the device, the
  other waits for it, and both boot from it.
- A session's churn of small objects, with the guest reporting free pages
  from order 0 and from the kernel's own order: the processor time of
  each, and what the VMM held at the session's release, are printed.

Then a person's sessions run in their own VM (plan V2), each case on a
stack of its own: docker-compose.yml's locus service, as harness.py runs
it, given the two devices as cyfr writes them to .env on a machine that
has them (CYFR_LOCUS_KVM, CYFR_LOCUS_TUN): /dev/kvm and /dev/net/tun for
the locus container and /dev/net/tun for the guard; without them the same
file gives /dev/null at those paths, as on a machine with none. Its pool's
work is sized as memory.py sizes it. Every session runs the probe program from
its environment (`vm_probe`): a VM's root is the image's programs alone,
which hold nothing of the container's /probe mount.

- The disk and the boot: the keeper says it gives the wall. A person's
  first session makes their disk an image, a regular file of the disk's
  uid and group, 0600, its record of the image form, and no disk folder,
  and runs in a VM under that uid: its boot identity is not the
  container's. Started again on the same kept volume without the devices,
  the keeper says it gives spaces, and the person's next session is
  refused, the keeper naming the disk image that runs only in a VM, with
  no VM booted and nothing of the image changed. Then the README's way out
  on such a machine: with Locus stopped, that person's disk's record in
  `.disks` and its image beside it removed from the homes volume, the next
  start makes them a new disk, of the directory form, and their session
  opens on it.
- Boot identity: one person's two sessions, each a space of its own, read
  one boot identity, and a second person's session another, each person's
  VM under their own disk's uid.
- Routes and names: one person's two programs, given different hosts, run
  in one VM; each reaches its own host and is refused the other's at once,
  on the guest's own route of that session, while the host's guard holds
  the VM's one route to both. A session's names are answered through the
  VM's card and the host's guard (Docker's answer for the stack's own
  service name), and another person's session finds nothing of the first
  person's disk, image or homes.
- Packs in a VM: a generation put for a session in a VM is its space's
  read-only folder at the path a host gives it, byte for byte: its
  executable runs from there, and nothing there is written, made or
  renamed. A newer generation put while that session runs reaches a new
  session in the same VM, while the old session still reads its own.
- Scratch sessions in a VM: a person whose programs are all scratch has no
  disk until their first session makes its record and image and boots
  their VM in it, the image's allocated size printed. That session is
  refused the Locus container's own address, cyfr's host API and
  endpoint, the VM's names address off its port 53 and the VM's gateway.
  Beside a person's kept session a scratch one runs in the same VM. A
  scratch session released leaves the next of the person's nothing: no
  marker in the first's home, its own or /tmp, no process of the first's
  uid, and none of the first's home's bytes on the guest's filesystem of
  scratch homes.
- The ledger (plan native-locus section 23), on the pool report: while a
  person's first session starts, `used` holds at least a session's
  allowance and the VM's own; past the allowance's time it is the VMM's
  group's reading, and the counters' bytes, the sessions' by subject, sum
  to no more. A second session of the person joins and `used` is still
  the VM's reading, not the VM's and the session's. In a pool that holds
  one VM's start and not two, a second person's start is refused
  `capacity` while the first person's session lives on; once that session
  has ended, the second person's start makes the first person's idle VM
  give way and is admitted, and with the first VM released `used` and
  `free` are what they were before its boot, beside the second VM's own
  charge.
- Losses on the host's side: the VMM killed with two sessions running ends
  both, each told it ended by a signal with no exit status and no memory
  cause, the program's status naming SIGKILL; the VM is released, and the
  person's next session boots a new VM. The guard killed during a
  session's start ends the VM, which the keeper says before it says it
  ends, its role's route gone with the guard; the start is refused 503 or
  its connection cut, and once the container starts again behind the
  guard's successor the person's next session boots a VM. The keeper
  killed while a VM holds the disk ends its container's life, and every
  VMM with it: the next life finds no VMM and no group of the VM, and the
  person's next session boots a VM on the same image, finding what the
  last one synced.
- Folders: with the person's VM ended, a reset of one of their homes boots
  their VM for it, which the keeper's log says is for a folder's reset,
  and answers the home empty; a retirement of another home then needs no
  boot of its own, answers it absent and takes it out of the disk's
  record, which still holds the first; the next session in the reset home
  joins the VM the reset booted and finds the home empty under its uid.
- Measurements, printed. At a guest of 2,560 MiB: the guest's memory and
  processors as the keeper configured the VMM, the VMM's resident memory
  and its group's memory after a person's first boot and after an idle
  minute, the disk image's allocated size at each, the guard container's
  peak with one VM routed, and the VMM's memory with a session binding the
  largest generation a set may be. Then a VM's own cost at guests of
  2,560 MiB, 8 GiB and the shipped sizing's rest, each the pool's rest,
  three fresh VMs each: the guest's MemTotal and the VMM group's
  memory.current and memory.stat at rest after its first session answered,
  while a session answers and once it is released, every reading a raw line
  and their ranges a table.

Prerequisites: harness.py's, /dev/kvm and /dev/net/tun on the host, and
the public network for the routes case's reaching steps, which are
skipped, each with its reason, under CYFR_TEST_OFFLINE=1. Usage:
tests/locus-backends-image/vm.py IMAGE
"""

import hashlib
import json
import os
import re
import secrets
import sys
import threading
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    CONNECT_PROBE, ENDPOINT_ADDRESS, GUARD, HERE, HOME_ROOT, KEPT_ROOT, NETWORK, POOL_FIRST, POOL_LAST, PORT, REFUSED,
    RELEASE, ROLE, SERVICE, VERSION, Stack, disk_of, eventually, expect, home_of, owner_of, require_docker,
)
import imagesuite  # noqa: E402
from imagesuite import PROJECT_PREFIX, read_output, run  # noqa: E402
import packs  # noqa: E402

KVM = "/dev/kvm"
# The machines' folder, the guest volume's mount point, as the role table names it.
GUEST_ROOT = ROLE["guest_root"]
BOOT_ID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
# The machines' folders, on the Locus container's run directory's tmpfs
# (internal/vm's Root). Each machine's uid is its own, which the report
# names and the VMM's process is held to.
MACHINES = RELEASE["run_dir"] + "/machines"
# What the VMM's space may write, by its filesystem: the space's own fresh
# mounts, and /dev's nodes, kvm among them, bound from the container's /dev.
# Its own machine's folder, a tmpfs too, is the one the report names.
VMM_WRITABLE = {"/proc": "proc", "/tmp": "tmpfs", "/var/tmp": "tmpfs", "/run": "tmpfs", "/dev": "tmpfs",
                "/dev/pts": "devpts", "/dev/shm": "tmpfs",
                **{f"/dev/{node}": "tmpfs" for node in ("null", "zero", "full", "random", "urandom", "tty", "kvm")}}
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
    args += ["--entrypoint", "cyfr-locus", image, "guest-check", "--kept-root", KEPT_ROOT, *extra]
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


def device_file(image, volume, device, path):
    """The body of the file at path in the device, from the image's own unsquashfs."""
    name = os.path.basename(device)
    return run("docker", "run", "--rm", "--network", "none", "--mount",
               f"type=volume,source={volume},target=/v,readonly", "--entrypoint", "unsquashfs", image,
               "-cat", f"/v/{name}", path.lstrip("/")).stdout



def kvm_gid():
    return os.stat(KVM).st_gid


def guest_lines(stderr):
    """The guest's console as the check kept it, without its mark."""
    return [line[len("guest: "):] for line in stderr.splitlines() if line.startswith("guest: ")]


def vmm_confined(report, what):
    vmm = report.get("vmm") or {}
    expect(not vmm.get("error"), f"{what}: the VMM's process is read from the host", vmm)
    machine = report.get("uid", 0)
    expect(machine > 0 and not POOL_FIRST <= machine <= POOL_LAST, f"{what}: the machine's uid is its own, no pool's", machine)
    uid, gid = str(machine), str(kvm_gid())
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
    folder = report.get("folder", "")
    expect(folder.startswith(f"{MACHINES}/{uid}-") and machines == [folder],
           f"{what}: the VMM's space holds its own machine's folder, the one the check names, and no other",
           f"{machines}, the check's {folder!r}")
    # What it may write, each by the filesystem its place holds: its folder,
    # the space's own fresh mounts and /dev's nodes. The image's directories,
    # the device and the rest are read only.
    own = {**VMM_WRITABLE, folder: "tmpfs"}
    for m in mounts:
        point = m.get("point")
        if point in own:
            expect(m.get("type") == own[point], f"{what}: the VMM's {point} is {own[point]}", m)
        else:
            expect(m.get("access") == "ro", f"{what}: nothing is writable in the VMM's space but its own", m)
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
    ready = [i for i, line in enumerate(console) if line.startswith("[cyfr-guard] info: ready: every rule installed")]
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
    exited = report.get("exited") or {}
    expect(exited.get("spawn_id") and exited.get("spawn_id") == spawned.get("spawn_id"),
           f"{what}: the exit is the space's own spawn's", f"{exited}, spawned {spawned}")
    expect(exited.get("code") == 0, f"{what}: the space exits 0", exited)
    expect(report.get("released") is True, f"{what}: the guest's keeper releases the space", report)
    expect(report.get("end") == "acknowledged", f"{what}: the machine's end is the acknowledged one", report)
    expect(report.get("group_procs") == [], f"{what}: no process is left in the machine's group", report)
    vmm_confined(report, what)


def processes(container):
    """The container's processes, as (pid, uid, comm, cmdline)."""
    out = run("docker", "exec", container, "sh", "-c",
              "for d in /proc/[0-9]*; do [ -r $d/status ] || continue; "
              "printf '%s\\t%s\\t%s\\t%s\\n' \"${d#/proc/}\" \"$(awk '/^Uid:/ {print $2}' $d/status)\" "
              "\"$(cat $d/comm)\" \"$(tr '\\0' ' ' < $d/cmdline)\"; done", check=False).stdout
    return [tuple(line.split("\t", 3)) for line in out.splitlines() if line.count("\t") == 3]


def keeper_killed(stack, image, kept, guest, project):
    """The keeper killed while its container's PID namespace lives on leaves no VMM: its stage's parent-death
    signal, armed again after the stage became the machine's uid, ends the stage, and with it the VMM's space."""
    container = f"{project}-keeper-killed"
    run("docker", "run", "-d", "--name", container, "--network", "none", *role_args(stack),
        "--mount", f"type=volume,source={kept},target={KEPT_ROOT}",
        "--mount", f"type=volume,source={guest},target={GUEST_ROOT}", "--device", KVM,
        "--entrypoint", "sh", image, "-c", "exec sleep 900")
    try:
        errors = RELEASE["run_dir"] + "/keeper-killed.err"
        run("docker", "exec", "-d", container, "sh", "-c",
            f"exec cyfr-locus guest-check --kept-root {KEPT_ROOT} -- /bin/sh -c 'sleep 600' 2>{errors}")
        deadline = time.monotonic() + 60
        while not any(comm == "firecracker" for _, _, comm, _ in processes(container)) and time.monotonic() < deadline:
            time.sleep(0.2)  # sleep-ok: polls the container's processes until the VMM is up, bounded above
        expect(any(comm == "firecracker" for _, _, comm, _ in processes(container)), "the killed keeper's machine boots",
               run("docker", "exec", container, "tail", "-c", "3000", errors, check=False).stdout)
        keepers = [pid for pid, _, comm, cmdline in processes(container)
                   if comm == "cyfr-locus" and cmdline.split()[1:2] == ["guest-check"]]
        expect(len(keepers) == 1, "one keeper runs the machine", processes(container))
        run("docker", "exec", container, "sh", "-c", f"kill -KILL {keepers[0]}")
        deadline = time.monotonic() + 20

        def left():
            return [p for p in processes(container) if p[2] == "firecracker" or p[1] != "0"]
        while left() and time.monotonic() < deadline:
            time.sleep(0.2)  # sleep-ok: polls until the killed keeper's space has ended, bounded above
        expect(not left(), "the keeper killed with its PID namespace alive leaves no VMM and no process of a "
               "machine's uid", left())
    finally:
        run("docker", "rm", "--force", container, check=False)


# ————— a person's sessions in their VM (plan V2) —————

SESSION_ALLOWANCE = imagesuite.ALLOWANCE_BYTES["session"]
MIB = 1 << 20


def first_start(work):
    """What a person's first session holds while it starts in a pool of the work `work`: a session's allowance and
    the VM's own, which follows its guest's size, the pool's work."""
    return SESSION_ALLOWANCE + imagesuite.machine_bytes(work)


# The pool's work of a stack that gives the wall: two first starts at once fit it.
WORK = 2048 * MIB
FIRST_START = first_start(WORK)
# The pool's work that holds one VM's first start and not a second beside a running VM: the least whole MiB that
# holds a first start in it and 16 MiB more.
TIGHT_WORK = next(w for w in range(first_start(0), WORK, MIB) if w >= first_start(w) + 16 * MIB)
# How far apart the keeper's charge of a VM and the suite's own reading of its group may be: the two are read at
# different instants of a guest that is idle but not still.
CHARGE_SLACK = 16 * MIB
# What the keeper says of the wall at its start, and of the losses and ends it meets.
WALL_SAID = "each person's work runs in a separate small computer on this machine"
SPACES_SAID = "each person's work runs in its own space on this machine: the container was given no /dev/kvm"
NO_VM_SAID = "is on a disk image, which runs only in its person's VM, and this machine runs none"
# Every boot of a person's VM, whatever it is for, and one for a folder's reset.
BOOTED_SAID = ", its VMM pid"
RESET_BOOT_SAID = "booted for a folder's reset, its VMM pid"
GIVE_WAY_SAID = "a person's VM ends: it held no session, and a start needs its room"
RELEASED_SAID = "a person's VM is released: its group is empty, its route withdrawn and its device let go"
SESSION_RELEASED_SAID = "released in its person's VM"
UNKEPT_RETIRED_SAID = "which held no kept home, is retired with its VM"
# The guard's connection ended (serve's guardLost): the VMs routed over it are killed, each group found empty, and
# then, the role's route having gone too, the keeper says it ends.
VMS_KILLED_SAID = re.compile(r"egress: the guard's connection (\d+) ended; (\d+) people's VMs are killed")
# A VM whose boot ended after the guard's loss found the VMs routed over its connection is killed by its boot, which
# sees the connection lost once the VM is set (serve's bootMachine).
BOOT_LOST_SAID = "a person's VM ends: the guard's connection its route was made over ended as it booted"
KEEPER_ENDS_SAID = re.compile(r"egress: the guard's connection (\d+) ended under the routes of roles .*; "
                              r"the keeper ends")
# A keeper that could not end or remove a group an earlier one left refuses to start (cgroup.Tree.Role), which ends
# them silently otherwise.
EARLIER_GROUPS_SAID = re.compile(r"the groups? an earlier keeper left")
# The VMM, as its stage executes it (internal/vm's Firecracker).
FIRECRACKER = "/usr/lib/cyfr/guest/firecracker"


def row_of(owner):
    """The home of the owner's one program in these cases: a kept home's id names one athanor's home alone."""
    return "mcp_" + owner["athanor"].removeprefix("ath_") + "-home"

# The packs' folder of a session's space, on a host and in a VM alike (packs.py).
SCROLLS = "/run/cyfr/scrolls"

with open(os.path.join(HERE, "probe-backend.mjs"), encoding="utf-8") as _probe:
    PROBE_SOURCE = _probe.read()


def vm_probe(name="probe", **program):
    """The probe program, a kept one unless `program` names its home, as a session in a VM runs it: its source carried
    in its environment, since a VM's root is the image's programs alone and holds nothing of the container's /probe
    mount."""
    return {"name": name, "command": 'exec node --input-type=module -e "$PROBE_SOURCE"',
            "env": {"PROBE_SOURCE": PROBE_SOURCE}, "home": "kept", **program}


def wall_stack(name, image):
    """A stack of its own that gives the wall: given the two devices, as cyfr writes them where the machine has them."""
    return Stack(f"locus-backends-vm-{name}", image, devices=True)


def up_wall(stack, work=WORK):
    """Starts the stack at the pool's work `work`, and waits for the keeper to say it gives the wall."""
    stack.up(work_bytes=work)
    eventually(lambda: WALL_SAID in stack.logs(), "the keeper to say it gives the wall", timeout_s=30)


def synced(stack, owners):
    """A controller of the stack that has greeted it and synced each owner's programs, `owners` being (owner,
    programs) pairs."""
    c = stack.controller()
    expect(c.hello()[0] == 200, "the service is greeted")
    for owner, programs in owners:
        status, answer, _ = c.sync(owner, programs, lease_ms=60_000)
        expect(status == 200, f"{owner['athanor']}'s programs are synced", answer)
    return c


def sh(c, owner, script, key="k", row=None, program="probe"):
    """`script` run by `sh -c` in the session of `key` of the owner's program, in its home `row` (`row_of` by
    default): the probe's answer."""
    return packs.run_in(c.mcp(owner, program, key=key, home_id=row or row_of(owner)), script)


def scratch_sh(c, owner, script, key="k", program="scratch"):
    """`script` run by `sh -c` in the scratch session of `key` of the owner's program, opened with no home: the probe's
    answer."""
    return packs.run_in(c.mcp(owner, program, key=key), script)


def boot_id(c, owner, key="k", row=None, program="probe"):
    """The boot identity the session of `key` reads."""
    read = sh(c, owner, "cat /proc/sys/kernel/random/boot_id", key, row, program)["stdout"].strip()
    if not BOOT_ID.match(read):
        sys.exit(f"FAIL: {owner['athanor']}'s session {key} reads no boot identity: {read!r}")
    return read


def container_boot(stack):
    """The Locus container's boot identity, its kernel's."""
    return read_output(stack.exec("cat /proc/sys/kernel/random/boot_id"), "the container's boot identity").strip()


def vmms(stack):
    """The VMMs running in the Locus container, {pid: uid}; none where it runs nothing."""
    return {p["pid"]: p["uids"][0] for p in stack.processes() if p["cmd"].split()[:1] == [FIRECRACKER]}


def person_of(owner):
    return disk_of(owner).rsplit("/", 1)[1]


def image_of(owner):
    """The owner's person's disk image: <kept root>/<sha256(athanor)>.img (the keeper's home.Kept.ImagePath)."""
    return disk_of(owner) + ".img"


def disk_record(stack, owner):
    """The keeper's record of the owner's person's disk, read by the observer."""
    path = f"{KEPT_ROOT}/.disks/{person_of(owner)}.json"
    return json.loads(read_output(stack.observe(f"cat {path}"), f"the record {path}"))


# An image's stat, every field a write to it changes among them: uid, gid, mode, size, inode, allocated blocks,
# modification and change times, then its type.
IMAGE_STAT = "%u %g %a %s %i %b %Y %Z %F"


def parse_stat(text, what):
    fields = text.strip().split(" ", 8)
    if len(fields) != 9:
        sys.exit(f"FAIL: {what} printed no stat: {text!r}")
    names = ["uid", "gid", "mode", "size", "inode", "blocks", "mtime", "ctime"]
    return {**{n: int(v) if n != "mode" else v for n, v in zip(names, fields)}, "type": fields[8]}


def image_stat(stack, owner):
    """The owner's disk image's stat, and whether a disk folder stands beside it, read by the observer."""
    out = read_output(stack.observe(f"stat -c '{IMAGE_STAT}' {image_of(owner)}; "
                                    f"test -e {disk_of(owner)} && echo folder || echo none"),
                      f"the stat of {image_of(owner)}").splitlines()
    return parse_stat(out[0], image_of(owner)), out[1] == "folder"


def volume_image_stat(stack, image, owner):
    """The image's stat read from the kept volume by a container of its own, while the stack's Locus is stopped."""
    out = run("docker", "run", "--rm", *imagesuite.run_name(f"{stack.project}-stat"), "--network", "none",
              "--mount", f"type=volume,source={stack.project}_homes,target={KEPT_ROOT},readonly",
              "--entrypoint", "stat", image, "-c", IMAGE_STAT, image_of(owner)).stdout
    return parse_stat(out, f"the volume's {image_of(owner)}")


def vmm_group(uid):
    """The group a person's VM's VMM runs in: under the backends role's group in work, named by its disk's uid."""
    return f"{imagesuite.work_group(ROLE)}/keeper-{uid}/bound"


def vmm_memory(stack, uid):
    """The VMM group's memory.current, and its reading as the keeper takes it (cgroup.Group.Used): anon, shmem and the
    kernel's, less what slab may reclaim."""
    group = vmm_group(uid)
    current = read_output(stack.exec(f"cat {group}/memory.current"), f"{group}/memory.current").strip()
    stat = imagesuite.read_counters(stack.exec(f"cat {group}/memory.stat"),
                                    ("anon", "shmem", "kernel", "slab_reclaimable"), f"{group}/memory.stat")
    return int(current), stat["anon"] + stat["shmem"] + stat["kernel"] - stat["slab_reclaimable"]


def group_gone(stack, uid):
    group = vmm_group(uid).removesuffix("/bound")
    return imagesuite.read_word(stack.exec(f"test -e {group} && echo present || echo absent"),
                                ("present", "absent"), f"the probe of {group}") == "absent"


def pool_report(stack):
    """One page of the backends role's pool report: its used, work and counters at one instant."""
    status, answer = imagesuite.pool_ask(stack.base, "backends", stack.key)
    if status != 200 or not isinstance(answer, dict):
        sys.exit(f"FAIL: the pool route answers {status}: {answer}")
    report = answer["report"]
    if "next" in report:
        sys.exit(f"FAIL: the pool report pages past {len(report['counters'])} counters: {report['next']}")
    return report


def ended(c, owner, session):
    """The session's last recv answer once it runs no more, or None."""
    status, answer = c.recv(owner, session, 0, 0)
    if status != 200:
        sys.exit(f"FAIL: a recv of {session} is refused: {status} {answer}")
    return None if answer["running"] else answer


def guard_routes(stack):
    """The guard's record of every route it holds, by its guard's end: the rules recorded for each."""
    listed = read_output(stack.guard_exec('for f in /run/cyfr-guard/routes/sp*; do [ -f "$f" ] && printf "== %s\\n" '
                                          '"${f##*/}" && cat "$f"; done; true'), "the guard's routes")
    out, iface = {}, None
    for line in listed.splitlines():
        if line.startswith("== "):
            iface = line[3:]
            out[iface] = []
        elif iface:
            out[iface].append(line)
    return out


def connects(c, owner, targets, key, row, program):
    """The kernel's answer to one connection from the session to each target (harness.py's CONNECT_PROBE)."""
    status, answer = c.mcp(owner, program, key=key, home_id=row).call(
        "run", {"argv": ["node", "-e", CONNECT_PROBE, "targets", *targets]})
    result = (answer or {}).get("result") or {}
    if status != 200 or result.get("isError") or "content" not in result:
        sys.exit(f"FAIL: the connection probe of {owner['athanor']}'s {program} session: {status} {answer}")
    probed = json.loads(result["content"][0]["text"])
    expect(probed["status"] == 0, f"{owner['athanor']}'s {program} session's connection probe ran to its end", probed)
    return dict(line.split("=", 1) for line in probed["stdout"].splitlines() if "=" in line)


def disk_and_boot(image):
    """A person's first session in a VM makes their disk an image and boots in it; without the devices the image's
    sessions are refused by name and nothing of the image changes."""
    stack = wall_stack("disk", image)
    owner = owner_of("vm-disk")
    try:
        up_wall(stack)
        c = synced(stack, [(owner, [vm_probe()])])
        guest = boot_id(c, owner)
        expect(guest != container_boot(stack), "the person's first session runs in a VM: its boot identity is not "
               "the container's", guest)
        record = disk_record(stack, owner)
        stat, folder = image_stat(stack, owner)
        expect(record["form"] == "image" and record["athanor"] == owner["athanor"]
               and record["homes"] == [row_of(owner)],
               "the person's disk is recorded of the image form, holding the session's home", record)
        expect(stat["type"] == "regular file" and stat["uid"] == stat["gid"] == record["uid"] and stat["mode"] == "600"
               and not folder, "the disk is an image, a regular file of the disk's uid and group, 0600, and no "
               "disk folder stands", [stat, folder])
        machines = vmms(stack)
        expect(list(machines.values()) == [record["uid"]], "the person's one VMM runs under their disk's uid",
               machines)
        print(f"the first session's image: {stat['size'] >> 30} GiB apparent, {stat['blocks'] * 512 // MIB} MiB "
              "allocated", flush=True)

        stack.compose("stop", SERVICE)
        before = volume_image_stat(stack, image, owner)
        stack.devices = False
        stack.up(work_bytes=WORK)
        eventually(lambda: SPACES_SAID in stack.logs(), "the keeper without the devices to say it gives spaces",
                   timeout_s=30)
        c = synced(stack, [(owner, [vm_probe()])])
        status, answer = c.open(owner, "probe", key="spaces", home_id=row_of(owner))
        expect(status != 200, "without the devices the person's next session is refused", [status, answer])
        logs = stack.logs()
        expect(NO_VM_SAID in logs and f"kept home {row_of(owner)} {NO_VM_SAID}" in logs,
               "the keeper names the disk image, which runs only in its person's VM, as why", logs[-3000:])
        expect(BOOTED_SAID not in logs and not vmms(stack), "no VM boots", logs[-3000:])
        after, folder = image_stat(stack, owner)
        expect(after == before and not folder, "nothing of the image changes, and no disk folder is made",
               [before, after])
        expect(disk_record(stack, owner) == record, "the disk's record is as it was")

        # The README's way out on a machine that no longer gives the devices: with Locus stopped, the person's disk
        # removed by hand from the homes volume, its record in .disks and its image beside it, as root removes them;
        # the next start makes the person a new disk, of the directory form, and their session opens on it.
        stack.compose("stop", SERVICE)
        removed = run("docker", "run", "--rm", *imagesuite.run_name(f"{stack.project}-remove"), "--network", "none",
                      "-u", "0", "--mount", f"type=volume,source={stack.project}_homes,target={KEPT_ROOT}",
                      "--entrypoint", "rm", image, f"{KEPT_ROOT}/.disks/{person_of(owner)}.json", image_of(owner),
                      check=False)
        expect(removed.returncode == 0, "the person's disk's record and image are removed from the homes volume",
               removed.stderr)
        stack.up(work_bytes=WORK)
        eventually(lambda: SPACES_SAID in stack.logs(), "the keeper's next start without the devices", timeout_s=30)
        c = synced(stack, [(owner, [vm_probe()])])
        again = sh(c, owner, 'id -u; ls -A "$HOME"', "again")
        renewed = disk_record(stack, owner)
        expect(again["status"] == 0 and renewed["form"] == "directory" and renewed["homes"] == [row_of(owner)],
               "the person's next session opens on a new disk, of the directory form", [again, renewed])
        image_left = read_output(stack.observe(f"test -e {image_of(owner)} && echo present || echo absent"),
                                 "the probe of the old image").strip()
        expect(image_left == "absent" and not vmms(stack), "the old image stays gone and no VM boots",
               [image_left, vmms(stack)])
    finally:
        stack.down()


def boot_identity(image):
    """One person's sessions share their VM's boot identity, and another person's VM has its own."""
    stack = wall_stack("boot", image)
    one, two = owner_of("vm-one"), owner_of("vm-two")
    try:
        up_wall(stack)
        c = synced(stack, [(one, [vm_probe()]), (two, [vm_probe()])])
        first, second, other = boot_id(c, one, "a"), boot_id(c, one, "b"), boot_id(c, two, "a")
        spaces = [sh(c, one, "readlink /proc/self/ns/pid", key)["stdout"] for key in ("a", "b")]
        expect(first == second and spaces[0] != spaces[1],
               "one person's two sessions, each a space of its own, read one boot identity", [first, second, spaces])
        expect(other != first and container_boot(stack) not in (first, other),
               "a second person's session reads another, and neither is the container's", [first, other])
        machines = sorted(vmms(stack).values())
        expect(machines == sorted([disk_record(stack, one)["uid"], disk_record(stack, two)["uid"]]),
               "each person's VM runs under their own disk's uid", machines)
    finally:
        stack.down()


NPM, ONE_ONE = "registry.npmjs.org", "one.one.one.one"
NPM_ROW, ONE_ROW = "mcp_vm-npm", "mcp_vm-one"


def routes_and_names(image):
    """One person's sessions with different hosts keep their own routes in one VM; names are answered through the
    host's guard; another person finds nothing of theirs."""
    offline = os.environ.get("CYFR_TEST_OFFLINE") == "1"
    stack = wall_stack("routes", image)
    person, other = owner_of("vm-routes"), owner_of("vm-neighbour")
    try:
        up_wall(stack)
        c = synced(stack, [(person, [vm_probe("npm", hosts=[NPM]), vm_probe("one", hosts=[ONE_ONE])]),
                           (other, [vm_probe()])])
        sessions = [("npm", NPM_ROW, f"{NPM}:443", "1.1.1.1:443"), ("one", ONE_ROW, "1.1.1.1:443", f"{NPM}:443")]
        boots = {boot_id(c, person, "k", row, program) for program, row, _own, _theirs in sessions}
        expect(len(boots) == 1, "the person's two programs run in one VM", boots)
        named = sh(c, person, f"getent hosts {SERVICE}", "k", NPM_ROW, "npm")
        expect(named["status"] == 0 and SERVICE in named["stdout"],
               f"a session's names are answered through the host's guard: Docker's answer for {SERVICE}", named)
        npm = sh(c, person, f"getent ahostsv4 {NPM} | awk '{{print $1}}' | sort -u", "k", NPM_ROW, "npm")
        npm_addrs = npm["stdout"].split()
        expect(npm["status"] == 0 and npm_addrs and "1.1.1.1" not in npm_addrs,
               f"{NPM} resolves in the VM to addresses of its own", npm)
        for program, row, own, theirs in sessions:
            codes = connects(c, person, [own, theirs], "k", row, program)
            expect(codes.get(theirs) in REFUSED,
                   f"the {program} session is refused the other session's host, {theirs}, at once", codes)
            if offline:
                print(f"skip: the {program} session's {own} is not reached: CYFR_TEST_OFFLINE=1 says this host has "
                      "no public network", flush=True)
            else:
                expect(codes.get(own) == "connected", f"the {program} session reaches its own host, {own}", codes)
        routes = guard_routes(stack)
        both = [iface for iface, rules in routes.items()
                if any("-d 1.1.1.1/32" in r for r in rules)
                and any(f"-d {a}/32" in r for r in rules for a in npm_addrs)]
        expect(len(both) == 1, "the host's guard holds the VM one route, allowing both sessions' hosts", routes)

        apart = sh(c, other, f"ls -A {KEPT_ROOT}; for p in {disk_of(person)} {image_of(person)} "
                             f"{home_of(person, NPM_ROW)}; do test -e $p && echo reached $p || echo no $p; done")
        expect(person_of(person) not in apart["stdout"].splitlines()[:-3]
               and apart["stdout"].splitlines()[-3:] == [f"no {disk_of(person)}", f"no {image_of(person)}",
                                                         f"no {home_of(person, NPM_ROW)}"],
               "another person's session finds nothing of the person's disk, image or homes", apart)
        print(f"another person's session lists under the kept root: {apart['stdout'].splitlines()[:-3]}", flush=True)
    finally:
        stack.down()


PACKS_ROW = "mcp_vm-packs"
# A newer generation of the same packs: one file's bytes changed.
NEWER = {**packs.FILES,
         "pstack/skills/poteto-mode/SKILL.md": (b"---\nname: poteto-mode\n---\n# the newer one\n", False)}


def packs_in_vm(image):
    """A person's packs are their VM session's read-only folder, and a newer generation reaches a new session while an
    old one keeps its own."""
    stack = wall_stack("packs", image)
    owner = owner_of("vm-packs")
    try:
        up_wall(stack)
        c = synced(stack, [(owner, [vm_probe(packs=True)])])
        digest = packs.digest_of(packs.FILES)
        state, puts, old = packs.started(c, owner, "old", PACKS_ROW, digest)
        expect(state == "missing" and puts and all(s == 200 for s, _a in puts) and puts[-1][1]["state"] == "held",
               "a first start finds the person's packs missing and puts them, the last part held", puts)
        listing = packs.run_in(old, f"cat /proc/sys/kernel/random/boot_id; find {SCROLLS} -type f | sort; echo; "
                                    f"find {SCROLLS} -type f | sort | xargs sha256sum")
        first, rest = listing["stdout"].split("\n", 1)
        expect(first.strip() != container_boot(stack), "the session that binds the packs runs in the person's VM",
               listing)
        names, sums = rest.split("\n\n", 1)
        expect(names.split() == sorted(f"{SCROLLS}/{p}" for p in packs.FILES),
               f"the VM session's {SCROLLS} holds the packs as put, at the path a host gives it", names)
        for path, (data, _x) in packs.FILES.items():
            expect(f"{hashlib.sha256(data).hexdigest()}  {SCROLLS}/{path}" in sums, f"{path} is the bytes put", sums)
        tried = packs.run_in(old,
                             f"{SCROLLS}/pstack/skills/poteto-mode/scripts/hello; "
                             f"touch {SCROLLS}/pstack/new 2>&1; echo rc=$?; "
                             f"mkdir {SCROLLS}/pstack/skills/poteto-mode/scripts/node_modules 2>&1; echo rc=$?; "
                             f"mv {SCROLLS}/taste {SCROLLS}/gone 2>&1; echo rc=$?; "
                             f"sh -c 'echo x >> {SCROLLS}/taste/skills/taste/SKILL.md' 2>&1; echo rc=$?; "
                             f"grep ' {SCROLLS} ' /proc/self/mountinfo")
        out = tried["stdout"]
        expect(out.startswith("hello from a pack\n"), "a pack's executable runs from the folder in the VM", out)
        expect(out.count("Read-only file system") == 3 and "Permission denied" in out and "rc=0" not in out,
               "a new file, a new folder and a rename fail read only, and an append is refused", out)
        mount = [line for line in out.splitlines() if f" {SCROLLS} " in line]
        expect(len(mount) == 1 and " ro," in mount[0], "the folder is a read-only mount of the session's space", mount)

        newer = packs.digest_of(NEWER)
        state, puts, new = packs.started(c, owner, "new", PACKS_ROW, newer, files=NEWER)
        expect(state == "missing" and puts[-1][1]["state"] == "held",
               "a newer generation is put while the old session runs", puts)
        skill = f"cat /proc/sys/kernel/random/boot_id; cat {SCROLLS}/pstack/skills/poteto-mode/SKILL.md"
        seen_new, seen_old = packs.run_in(new, skill)["stdout"], packs.run_in(old, skill)["stdout"]
        expect(seen_new.split("\n", 1)[0] == first.strip()
               and seen_new.split("\n", 1)[1] == NEWER["pstack/skills/poteto-mode/SKILL.md"][0].decode(),
               "the newer generation reaches a new session in the same VM", seen_new)
        expect(seen_old.split("\n", 1)[1] == packs.FILES["pstack/skills/poteto-mode/SKILL.md"][0].decode(),
               "the old session still reads its own generation", seen_old)
    finally:
        stack.down()


# What a scratch session writes in its home, to find on the guest's filesystem of scratch homes.
MARKER_BYTES = 4 * MIB
# The filesystem that holds $HOME: its blocks, free blocks and block size.
STATFS = "stat -f -c '%b %f %S' \"$HOME\""


def statfs_used(line):
    """The bytes a filesystem holds, from its STATFS line."""
    blocks, free, size = (int(field) for field in line.split())
    return (blocks - free) * size


def scratch_in_vm(image):
    """A person's scratch sessions run in their VM: a scratch-only person's first one makes their disk and boots it,
    reaching nothing of the host; beside a kept session one joins the same VM, and one released leaves the next
    nothing of it."""
    stack = wall_stack("scratch", image)
    alone, both = owner_of("vm-scratch-only"), owner_of("vm-scratch-kept")
    # The probe with no home and no hosts: a scratch program of the island's reach.
    scratch = vm_probe("scratch", home="scratch")
    try:
        up_wall(stack)
        c = synced(stack, [(alone, [scratch])])

        def scratch_boot(owner, key):
            read = scratch_sh(c, owner, "cat /proc/sys/kernel/random/boot_id", key)["stdout"].strip()
            if not BOOT_ID.match(read):
                sys.exit(f"FAIL: {owner['athanor']}'s scratch session {key} reads no boot identity: {read!r}")
            return read

        record_path = f"{KEPT_ROOT}/.disks/{person_of(alone)}.json"
        expect(imagesuite.read_word(stack.observe(f"test -e {record_path} || test -e {image_of(alone)} && echo present "
                                                  "|| echo absent"), ("present", "absent"),
                                    "the probe of the disk's record and image") == "absent",
               "a person whose programs are all scratch has no disk: no record and no image")
        # A new person's first scratch session's start: its disk's record and image made, the programs' device
        # made or found, and the VM booted, all inside the role's bound on a spawn's answer (15 s).
        # Its first request opens it: the time from that request to its answer holds the spawn's and more (the
        # program's start, its handshake and the command), so the spawn's own is less.
        began = time.monotonic()
        guest = scratch_boot(alone, "a")
        answered_s = time.monotonic() - began
        expect(answered_s < 15, "a scratch-only person's first session answers within the role's 15 s bound on a "
               "spawn's answer", f"{answered_s:.1f} s")
        print(f"a scratch-only person's first session answered its first command {answered_s:.1f} s after it was "
              "asked: its disk's record and image made, the programs' device made or found, its VM booted, the "
              "program started and the command run", flush=True)
        record = disk_record(stack, alone)
        stat, folder = image_stat(stack, alone)
        machines = vmms(stack)
        expect(guest != container_boot(stack), "the scratch-only person's first session runs in a VM: its boot "
               "identity is not the container's", guest)
        expect(record["form"] == "image" and record["athanor"] == alone["athanor"] and stat["type"] == "regular file"
               and stat["uid"] == record["uid"] and not folder,
               "their first session made their disk's record, of the image form, and its image", [record, stat, folder])
        expect(list(machines.values()) == [record["uid"]], "their one VMM runs under the disk's uid", machines)
        print(f"a scratch-only person's image after its first boot: {allocated(stack, alone)} MiB allocated of "
              f"{stat['size'] >> 30} GiB", flush=True)

        guard = stack.inspect(stack.guard)
        own = guard["NetworkSettings"]["Networks"][f"{stack.project}_{NETWORK}"]["IPAddress"]
        host_api = next(e.split("=", 1)[1] for e in guard["Config"]["Env"] if e.startswith("CYFR_GUARD_HOST_API="))
        _pid, api = vmm_process(stack)
        targets = {
            # The Locus container's address on the locus network, its guard's, whose namespace it shares, at the
            # backends role's port, which the guard forwards to the role's listener: the wire that starts every session.
            f"{own}:{PORT}": "the Locus container's own address",
            # cyfr's address on the locus network, at its host API, the one port of cyfr's the guard opens to a route
            # (the runtime role's).
            host_api: "cyfr's host API",
            # cyfr's fixed endpoint address, the control plane's, which the guard refuses every route.
            f"{ENDPOINT_ADDRESS}:4000": "cyfr's endpoint",
            # The address the guard's name sockets answer the VM at, on the bridge in the VMM's own namespace on the
            # host, off the one port they serve.
            "169.254.0.53:80": "the VM's names address off its port 53",
            # The guard's end of the VM's route, in the namespace the Locus container shares, at the backends role's
            # port.
            f"{vm_gateway(stack, api)}:{PORT}": "the VM's gateway",
        }
        codes = connects(c, alone, list(targets), "a", None, "scratch")
        for target, what in targets.items():
            expect(codes.get(target) in REFUSED, f"the scratch session is refused {what}, {target}, at once", codes)

        # A disk that has never held a kept home goes with its VM (the keeper's retireUnkept): the VMM killed, the
        # VM's release retires its record and its image, and the person's next first session makes both again within
        # the role's bound.
        said = stack.logs().count(RELEASED_SAID)
        killed = run("docker", "exec", "-u", "0", stack.container, "kill", "-KILL",
                     str(next(pid for pid, u in vmms(stack).items() if u == record["uid"])), check=False)
        expect(killed.returncode == 0, "the scratch-only person's VMM is killed", killed.stderr)
        eventually(lambda: stack.logs().count(RELEASED_SAID) > said, "the scratch-only person's VM's release")
        eventually(lambda: imagesuite.read_word(stack.observe(f"test -e {record_path} || test -e {image_of(alone)} && "
                                                              "echo present || echo absent"), ("present", "absent"),
                                                "the probe of the disk's record and image") == "absent",
                   "the never-kept disk's retirement with its VM, its record and its image gone")
        expect(UNKEPT_RETIRED_SAID in stack.logs(), "the keeper says the never-kept disk is retired with its VM")
        began = time.monotonic()
        again = scratch_boot(alone, "b")
        again_s = time.monotonic() - began
        expect(again != guest and again_s < 15 and disk_record(stack, alone)["uid"] > 0,
               "the person's next first session makes their disk again and boots a new VM within the role's 15 s",
               f"{again_s:.1f} s")
        print(f"after its retirement, the scratch-only person's next first session answered in {again_s:.1f} s",
              flush=True)

        status, answer, _ = c.sync(both, [vm_probe(), scratch], lease_ms=60_000)
        expect(status == 200, f"{both['athanor']}'s programs are synced", answer)
        kept = boot_id(c, both, "k")
        uid = disk_record(stack, both)["uid"]
        theirs = [pid for pid, u in vmms(stack).items() if u == uid]
        first_boot = scratch_boot(both, "first")
        expect(first_boot == kept and [pid for pid, u in vmms(stack).items() if u == uid] == theirs
               and len(theirs) == 1,
               "beside the person's kept session their scratch session runs in the same VM, its place needing no "
               "second", [kept, first_boot, theirs, vmms(stack)])

        # The disk's work folder is its kept programs' alone: a scratch session of the same person, in the same VM,
        # neither reads nor writes it, nor sees the kept homes' root it lies under.
        wrote = sh(c, both, "echo kept > /work/kept-marker && cat /work/kept-marker && echo written", "k")
        expect(wrote["stdout"] == "kept\nwritten\n", "the kept session writes in the disk's work folder", wrote)
        tried = scratch_sh(c, both, "cat /work/kept-marker 2>&1 && echo read; touch /work/scratch-marker 2>&1 && "
                                    f"echo wrote; ls {KEPT_ROOT} 2>&1 && echo listed; true", "first")
        steps = tried["stdout"].splitlines()
        expect(tried["status"] == 0 and not {"read", "wrote", "listed"} & set(steps) and "kept" not in steps,
               "a scratch session neither reads nor writes the disk's work folder, nor lists the kept homes' root",
               tried)
        looked_back = sh(c, both, "ls /work", "k")
        expect("scratch-marker" not in looked_back["stdout"].split(), "nothing a scratch session did is in the work "
               "folder", looked_back)

        marked = scratch_sh(c, both, f"id -u; echo \"$HOME\"; {STATFS}; head -c {MARKER_BYTES} /dev/urandom > "
                                     f"\"$HOME/marker\" && echo marked > /tmp/marker && {STATFS}", "first")
        lines = marked["stdout"].splitlines()
        expect(marked["status"] == 0 and len(lines) == 4, "the first scratch session writes its markers", marked)
        first_uid, first_home = int(lines[0]), lines[1]
        before, written = statfs_used(lines[2]), statfs_used(lines[3])
        expect(POOL_FIRST <= first_uid <= POOL_LAST and first_home.startswith(HOME_ROOT + "/"),
               "the scratch session runs under a uid of the guest's pool, its home under the scratch homes' root",
               lines[:2])
        expect(written - before >= MARKER_BYTES, "the guest's filesystem of scratch homes holds the marker's bytes",
               [before, written])
        session = c.mcp(both, "scratch", key="first").session
        released = stack.logs().count(SESSION_RELEASED_SAID)
        expect(c.close(both, session)[0] == 200, "the first scratch session is closed")
        eventually(lambda: stack.logs().count(SESSION_RELEASED_SAID) > released,
                   "the first scratch session's release in its VM", timeout_s=30)

        looked = scratch_sh(c, both, f"id -u; echo \"$HOME\"; cat /proc/sys/kernel/random/boot_id; {STATFS}; "
                                     f"for p in '{first_home}/marker' \"$HOME/marker\" /tmp/marker; do "
                                     "test -e \"$p\" && echo \"found $p\" || echo \"no $p\"; done; "
                                     "for d in /proc/[0-9]*; do awk '/^Uid:/ {print \"proc\", $2}' \"$d/status\" "
                                     "2>/dev/null; done", "second")
        lines = looked["stdout"].splitlines()
        expect(looked["status"] == 0 and len(lines) > 7, "a second scratch session of the person looks", looked)
        second_uid, second_home, second_boot = int(lines[0]), lines[1], lines[2]
        after = statfs_used(lines[3])
        uids = [line.split()[1] for line in lines[7:] if line.startswith("proc ")]
        expect(second_boot == first_boot, "the second scratch session runs in the same VM", [first_boot, second_boot])
        expect(lines[4:7] == [f"no {first_home}/marker", f"no {second_home}/marker", "no /tmp/marker"],
               "it finds neither of the first's markers, in the first's home, its own or /tmp", lines[4:7])
        # A space's /proc is its own pid namespace's: every process it lists is the second session's own.
        expect(uids and (second_uid == first_uid or str(first_uid) not in uids),
               f"it sees no process of the first's uid {first_uid} but its own", uids)
        expect(after <= before + MIB, "the guest's filesystem of scratch homes holds no more than before the first's "
               "marker: the first's home went at its release", [before, written, after])
        print(f"the second scratch session ran under uid {second_uid}, the first under {first_uid}; the guest's "
              f"scratch homes held {before / MIB:.1f} MiB before the first's marker, {written / MIB:.1f} MiB with it "
              f"and {after / MIB:.1f} MiB after its release", flush=True)
    finally:
        stack.down()


class Sampler(threading.Thread):
    """Reads the pool report's `used` and whether a VMM runs, every fifth of a second until stopped: (monotonic time,
    used, a VMM running) each time, or the failure that stopped it."""

    def __init__(self, stack):
        super().__init__(daemon=True)
        self.stack, self.stopped, self.samples, self.failure = stack, threading.Event(), [], None

    def run(self):
        try:
            while not self.stopped.is_set():
                used = pool_report(self.stack)["used"]
                running = imagesuite.listing(self.stack.exec(
                    'for d in /proc/[0-9]*; do [ "$(cat $d/comm 2>/dev/null)" = firecracker ] && echo ${d#/proc/}; '
                    'done; true'), "the container's VMMs").split()
                self.samples.append((time.monotonic(), used, bool(running)))
                self.stopped.wait(0.2)
        except (Exception, SystemExit) as error:
            self.failure = repr(error)


def charged_at_reading(stack, uid, what, timeout_s=40):
    """Waits until the pool report's `used` is the VMM group's reading, the keeper's one charge for the VM: answers
    (report, memory.current, the reading)."""
    def settled():
        report = pool_report(stack)
        current, reading = vmm_memory(stack, uid)
        return (report, current, reading) if abs(report["used"] - reading) <= CHARGE_SLACK else None
    return eventually(settled, what, timeout_s)


def ledger_one_vm(image):
    """The ledger of one VM: its first start holds a session's allowance and the VM's own, then the VMM's reading is
    the one charge, the counters sum to no more, and a second session of the person adds nothing to it."""
    stack = wall_stack("ledger", image)
    owner = owner_of("vm-ledger")
    try:
        up_wall(stack)
        c = synced(stack, [(owner, [vm_probe()])])
        before = pool_report(stack)
        sampler = Sampler(stack)
        sampler.start()
        try:
            status, answer = c.mcp(owner, "probe", key="a", home_id=row_of(owner)).request("tools/list", {})
            opened = pool_report(stack)
        finally:
            sampler.stopped.set()
            sampler.join()
        expect(status == 200 and "result" in answer, "the person's first session starts", answer)
        expect(sampler.failure is None, "the report and the VMM are read throughout the start", sampler.failure)
        running = [(t, used) for t, used, vmm in sampler.samples if vmm]
        expect(running, "the VMM was seen running during the start", sampler.samples[-10:])
        boot = running[0][0]
        held = [used for t, used in running if t < boot + 9]
        expect(held and min(held) >= FIRST_START,
               f"from the VMM's start on, while its allowance's time runs, used holds at least "
               f"{SESSION_ALLOWANCE // MIB} + {imagesuite.machine_bytes(WORK) // MIB} MiB",
               {"samples": [u // MIB for u in held], "least": FIRST_START // MIB})
        print(f"used before the first boot {before['used'] // MIB} MiB; during the start at least "
              f"{min(held) // MIB} MiB over {len(held)} readings; as the open answered {opened['used'] // MIB} MiB",
              flush=True)
        uid = disk_record(stack, owner)["uid"]
        report, current, reading = charged_at_reading(stack, uid, "used to be the VMM group's reading")
        counters = report["counters"]
        theirs = [k for k in counters if (k.get("athanor"), k.get("subject")) == (owner["athanor"], owner["server"])]
        print(f"one session: used {report['used'] / MIB:.1f} MiB, the VMM group's reading {reading / MIB:.1f} MiB, "
              f"its memory.current {current / MIB:.1f} MiB, the counters {[k['bytes'] // MIB for k in counters]} MiB",
              flush=True)
        expect(report["used"] <= current + CHARGE_SLACK, "used is no more than the VMM group's memory.current",
               [report["used"], current])
        expect(len(theirs) == 1 and theirs[0]["kind"] == "program" and theirs[0]["bytes"] > 0
               and all(k.get("athanor") and k.get("subject") for k in counters),
               "the session's reading is counted under its subject, and every counter is a session's", counters)
        expect(sum(k["bytes"] for k in counters) <= report["used"], "the counters' bytes sum to no more than used",
               [counters, report["used"]])

        expect(c.mcp(owner, "probe", key="b", home_id=row_of(owner)).request("tools/list", {})[0] == 200,
               "a second session of the person joins their VM")
        time.sleep(imagesuite.ALLOWANCE_MS / 1000 + 1)  # sleep-ok: the joining session's allowance holds this long
        report, current, reading = charged_at_reading(stack, uid, "used to be the VMM group's reading again")
        theirs = [k for k in report["counters"]
                  if (k.get("athanor"), k.get("subject")) == (owner["athanor"], owner["server"])]
        print(f"two sessions: used {report['used'] / MIB:.1f} MiB, the VMM group's reading {reading / MIB:.1f} MiB, "
              f"its memory.current {current / MIB:.1f} MiB, the counters "
              f"{[k['bytes'] // MIB for k in report['counters']]} MiB", flush=True)
        expect(len(theirs) == 1 and theirs[0]["bytes"] > CHARGE_SLACK
               and abs(report["used"] - reading) <= CHARGE_SLACK < theirs[0]["bytes"],
               "with a second session used is still the VM's reading, not the VM's and the sessions' together",
               {"used": report["used"], "reading": reading, "counter": theirs})
        expect(sum(k["bytes"] for k in report["counters"]) <= report["used"],
               "the counters' bytes still sum to no more than used", report)
    finally:
        stack.down()


def ledger_pressure(image):
    """In a pool holding one VM's start, a second person's start is refused while the first person's session lives,
    and makes their idle VM give way once it has ended; with that VM released the pool is as before but for the new
    VM."""
    stack = wall_stack("pressure", image)
    first, second = owner_of("vm-press-a"), owner_of("vm-press-b")
    try:
        up_wall(stack, TIGHT_WORK)
        c = synced(stack, [(first, [vm_probe()]), (second, [vm_probe()])])
        before = pool_report(stack)
        free_before = before["work"] - before["used"]
        routes_before = set(guard_routes(stack))
        a_boot = boot_id(c, first, "a")
        a_uid = disk_record(stack, first)["uid"]
        a_vmm = vmms(stack)
        expect(list(a_vmm.values()) == [a_uid], "the first person's VM runs", a_vmm)
        charged_at_reading(stack, a_uid, "the first VM to be charged its reading")

        started = time.monotonic()
        status, answer = c.open(second, "probe", key="b", home_id=row_of(second), timeout=90)
        waited = time.monotonic() - started
        expect(status == 409 and answer.get("error") == "capacity" and answer["held"]["need"] == first_start(TIGHT_WORK)
               and answer["held"]["mine"] == [] and answer["held"]["others_bytes"] > 0,
               "with the first person's session live, the second person's start is refused capacity, needing a "
               "session's allowance and a VM's", [status, answer])
        print(f"the second start was refused after {waited:.1f} s: {answer['held']}", flush=True)
        expect(boot_id(c, first, "a") == a_boot and vmms(stack) == a_vmm,
               "the first person's session lives on, in the same VM")

        said = stack.logs().count(RELEASED_SAID)
        session = c.mcp(first, "probe", key="a", home_id=row_of(first)).session
        expect(c.close(first, session)[0] == 200, "the first person's session is closed")
        eventually(lambda: ended(c, first, session), "the first person's session to end")
        expect(vmms(stack) == a_vmm, "the first person's VM outlives their last session")
        b_boot = boot_id(c, second, "b")
        logs = stack.logs()
        expect(GIVE_WAY_SAID in logs and logs.count(RELEASED_SAID) > said and not any(p in vmms(stack) for p in a_vmm),
               "the second person's start makes the first person's idle VM give way, which is released",
               logs[-3000:])
        expect(b_boot != a_boot, "the second person's start is admitted, in a VM of their own", [a_boot, b_boot])
        b_uid = disk_record(stack, second)["uid"]
        expect(group_gone(stack, a_uid), "the first VM's group is gone")
        routes = set(guard_routes(stack))
        expect(len(routes) == len(routes_before) + 1, "of the two VMs' routes the guard holds the second's alone",
               [sorted(routes_before), sorted(routes)])
        report, current, reading = charged_at_reading(stack, b_uid, "the second VM to be charged its reading")
        free = report["work"] - report["used"]
        print(f"before the first boot used {before['used'] // MIB} MiB and free {free_before // MIB} MiB; with the "
              f"first VM released and the second's reading {reading / MIB:.1f} MiB, used "
              f"{report['used'] / MIB:.1f} MiB and free {free / MIB:.1f} MiB", flush=True)
        expect(abs(report["used"] - (before["used"] + reading)) <= CHARGE_SLACK
               and abs(free - (free_before - reading)) <= CHARGE_SLACK,
               "with the first VM released, used and free are what they were before its boot, beside the second "
               "VM's own charge", {"before": before, "after": report, "reading": reading})
    finally:
        stack.down()


def vmm_killed(image):
    """The VMM killed with two sessions running ends both, each told it ended by a signal and the program's status
    naming SIGKILL, and releases the VM; the next session boots a new one."""
    stack = wall_stack("vmm-killed", image)
    owner = owner_of("vm-killed")
    try:
        up_wall(stack)
        c = synced(stack, [(owner, [vm_probe()])])
        first = boot_id(c, owner, "a")
        expect(boot_id(c, owner, "b") == first, "the person's two sessions run in their VM")
        sessions = [c.mcp(owner, "probe", key=key, home_id=row_of(owner)).session for key in ("a", "b")]
        machines = vmms(stack)
        expect(len(machines) == 1, "one VMM runs", machines)
        uid = disk_record(stack, owner)["uid"]
        said = stack.logs().count(RELEASED_SAID)
        pid = next(iter(machines))
        killed = run("docker", "exec", "-u", "0", stack.container, "kill", "-KILL", str(pid), check=False)
        expect(killed.returncode == 0, "the VMM is killed by the container's root", killed.stderr)
        answers = [eventually(lambda s=s: ended(c, owner, s), "a session to end with its VM") for s in sessions]
        told = [{k: v for k, v in a.items() if k != "lines"} for a in answers]
        print(f"the sessions' last answers: {told}", flush=True)
        # The VMM's end is each session's `exited` with signal SIGKILL and, its group's counters showing no OOM kill,
        # memory null (serve's machineEnded and followGuest). The backends role takes it as an end by a signal
        # (Locus.Backends.Backend's exit_end): a recv answers `running: false` with no `exit_code`, which only an
        # exit of the process's own accord with a status carries, and no `ended_by`, which only a memory cause does.
        expect(all(not a["running"] and "exit_code" not in a and "ended_by" not in a for a in answers),
               "both sessions end with their VMM, each told it ended by a signal, with no exit status and no memory "
               "cause", told)
        eventually(lambda: stack.logs().count(RELEASED_SAID) > said and not vmms(stack) and group_gone(stack, uid),
                   "the VM to be released, its VMM and its group gone")
        program = c.program(owner)
        print(f"the program's status after the VMM's kill: {program}", flush=True)
        # Each session's end counts as a crash of its key, whose error is the program's (Locus.Backends.Owners'
        # crashed): the end by SIGKILL spelled as the role spells an exit with no status.
        expect(program["error"] == "exited code=null signal=SIGKILL" and program["restarts"] == 2
               and program["sessions"] == 0 and program["status"] == "idle",
               "the program's status names the sessions' end by SIGKILL, counts both, and runs no session, no key "
               "failed", program)
        again = boot_id(c, owner, "c")
        expect(again != first and container_boot(stack) != again,
               "the person's next session boots a new VM", [first, again])
    finally:
        stack.down()


def folders_in_vm(image):
    """A folder's reset with no VM of its person's running boots their VM for it, which the keeper's log names as
    such, and leaves the home empty under its uid for the next session, which joins that VM; a retirement then needs
    no boot of its own, and takes the home out of the disk's record, which still holds the other."""
    stack = wall_stack("folders", image)
    owner = owner_of("vm-folders")
    reset_row, retired_row = row_of(owner), row_of(owner) + "-retired"
    try:
        up_wall(stack)
        c = synced(stack, [(owner, [vm_probe()])])
        for key, row in (("a", reset_row), ("b", retired_row)):
            wrote = sh(c, owner, f'echo {key} > "$HOME/marker" && cat "$HOME/marker"', key, row)
            expect(wrote["status"] == 0 and wrote["stdout"].strip() == key, f"a session writes into the home {row}",
                   wrote)
        uid = disk_record(stack, owner)["uid"]
        released = stack.logs().count(RELEASED_SAID)
        pid = next(iter(vmms(stack)))
        killed = run("docker", "exec", "-u", "0", stack.container, "kill", "-KILL", str(pid), check=False)
        expect(killed.returncode == 0, "the VMM is killed by the container's root", killed.stderr)
        eventually(lambda: stack.logs().count(RELEASED_SAID) > released and not vmms(stack) and group_gone(stack, uid),
                   "the VM to be released, its VMM and its group gone")

        said = stack.logs().count(RESET_BOOT_SAID)
        status, reset, _ = c.home(owner["athanor"], reset_row, "reset")
        expect((status, reset) == (200, {"version": VERSION, "home_id": reset_row, "state": "empty"}),
               "a folder's reset with no VM running answers the home empty", reset)
        booted = vmms(stack)
        expect(stack.logs().count(RESET_BOOT_SAID) == said + 1 and len(booted) == 1,
               "the reset booted the person's VM, and the keeper's log says it was for a folder's reset", booted)

        status, retired, _ = c.home(owner["athanor"], retired_row, "retire")
        expect((status, retired) == (200, {"version": VERSION, "home_id": retired_row, "state": "absent"}),
               "a folder's retirement answers the home absent", retired)
        expect(vmms(stack) == booted, "the retirement needed no boot of its own", vmms(stack))
        homes = disk_record(stack, owner)["homes"]
        expect(retired_row not in homes and reset_row in homes,
               "the retired home is out of the disk's record, the reset one in it", homes)

        after = sh(c, owner, 'id -u; ls -A "$HOME"; cat /proc/sys/kernel/random/boot_id', "c", reset_row)
        lines = after["stdout"].split()
        expect(after["status"] == 0 and lines[0] == str(uid) and "marker" not in lines and vmms(stack) == booted,
               "the next session finds the reset home empty under its uid, in the VM the reset booted", after)
    finally:
        stack.down()


def guard_lost_at_start(image):
    """The guard killed during a session's start ends the VM, which the keeper says before it says it ends with its
    role's route; the start is refused or its connection cut, and once the container is started again behind the
    guard's successor, the person's next session boots."""
    stack = wall_stack("guard-lost", image)
    owner = owner_of("vm-guard-lost")
    try:
        up_wall(stack)
        c = synced(stack, [(owner, [vm_probe()])])
        restarts = stack.inspect(stack.container)["RestartCount"]
        result = {}

        def start():
            try:
                result["open"] = c.open(owner, "probe", key="a", home_id=row_of(owner), timeout=90)
            except Exception as error:  # the guard's loss cuts the request's connection, in whatever form
                result["error"] = error
        opening = threading.Thread(target=start, daemon=True)
        opening.start()
        eventually(lambda: vmms(stack) or "open" in result or "error" in result, "the VMM to start", timeout_s=60)
        expect(vmms(stack) and not result, "the guard is lost while the session's start is under way, its VMM up",
               result)
        pids = read_output(stack.guard_exec("for p in /proc/[0-9]*; do grep -qa guard-control $p/cmdline 2>/dev/null "
                                            "&& echo ${p#/proc/}; done; true"), "the guard's processes").split()
        expect(pids, "the guard's control runs", pids)
        stack.guard_exec(f"kill -KILL {' '.join(pids)}")
        opening.join(120)
        print(f"the start's answer: {result}", flush=True)
        # The start meets the guard's loss one of two ways, by timing. Most often its connection is cut: the guard's
        # end takes its container's published port and the card of the namespace the role listens in, and the
        # keeper's guardLost kills the backends role's group, whose listener holds the request; the client reads an
        # OSError, a reset, a close with no answer or its timeout. Or the role answers the keeper's refusal first,
        # within the 20 ms the keeper's kill of the VM's group polls for its end (cgroup.Group.KillBy) before it kills
        # the role's: 503 guard_unavailable where the session's widening of the VM's route or the start's last check
        # met the guard's loss (serve's joinMachine, startInMachine), 503 unavailable where the start's link to the
        # guest met the VM's end (serve's machineLink, guestLost), each the role's refusal by its code
        # (Locus.Backends.Owners' spawn_refusal; the statuses of tests/fixtures/locus_backends.json).
        refusals = [(503, {"error": code, "version": VERSION}) for code in ("guard_unavailable", "unavailable")]
        expect(isinstance(result.get("error"), OSError) or result.get("open") in refusals,
               "the start under way is refused 503 guard_unavailable or unavailable, or its connection is cut", result)

        def again():
            info = stack.inspect(stack.container)
            return info["RestartCount"] > restarts and info["State"]["Running"]
        eventually(again, "the Locus container to start again", timeout_s=120)
        # The guard's container starts again too, its port published once it does.
        eventually(lambda: stack.compose("port", GUARD, str(PORT), check=False).stdout.strip(),
                   "the guard's port to be published again", timeout_s=120)
        stack.published()
        # The container's first life: its lines before the next life's keeper says it gives the wall, as each says
        # at its start (serve's giveWall).
        lines = stack.logs().splitlines()
        starts = [i for i, line in enumerate(lines) if WALL_SAID in line]
        first = lines[:starts[1]] if len(starts) > 1 else lines

        def said(pattern):
            return [(i, found) for i, line in enumerate(first) if (found := pattern.search(line))]
        killed, ends = said(VMS_KILLED_SAID), said(KEEPER_ENDS_SAID)
        at_boot = [i for i, line in enumerate(first) if BOOT_LOST_SAID in line]
        print("the keeper's first life said: " + " | ".join(
            first[i].split("|", 1)[-1].strip() for i in sorted([i for i, _ in killed + ends] + at_boot)), flush=True)
        # guardLost says the VMs are killed only once each one's group is empty, and says the keeper ends after it;
        # a VM whose boot had not yet set it when the loss looked is killed by its boot instead, before the keeper
        # ends.
        by_loss = len(killed) == 1 and killed[0][1].group(2) == "1" and killed[0][1].group(1) == ends[0][1].group(1) \
            if len(ends) == 1 else False
        by_boot = not killed and len(at_boot) == 1 and len(ends) == 1 and at_boot[0] < ends[0][0]
        expect(len(ends) == 1 and (by_loss and killed[0][0] < ends[0][0] or by_boot),
               "in the container's first life the keeper says the guard's connection ended and its one VM is killed, "
               "and then that it ends: the VM ended with the guard, before the container started again",
               "\n".join(first[-60:]))
        c = synced(stack, [(owner, [vm_probe()])])
        booted = boot_id(c, owner, "b")
        expect(booted != container_boot(stack) and len(vmms(stack)) == 1,
               "behind the guard's successor the person's next session boots a VM", booted)
    finally:
        stack.down()


def keeper_lost(image):
    """The keeper killed while a VM holds the disk ends its container's life, and every VMM with it: the next life
    finds no VMM and no group of the VM, and the person's next session boots a VM on the same image and finds what the
    last one synced."""
    stack = wall_stack("keeper-lost", image)
    owner = owner_of("vm-keeper-lost")
    try:
        up_wall(stack)
        c = synced(stack, [(owner, [vm_probe()])])
        # The guest's page cache ends with its VMM: what the session wrote is on the image for the next VM to find
        # only once the guest has synced it to its disk.
        wrote = sh(c, owner, 'echo kept > "$HOME/kept.txt" && sync && echo written', "a")
        expect(wrote["stdout"] == "written\n", "a session writes a file in its home", wrote)
        first = boot_id(c, owner, "a")
        record = disk_record(stack, owner)
        stat, _folder = image_stat(stack, owner)
        keepers = [p["pid"] for p in stack.processes() if p["cmd"].startswith("cyfr-locus serve")]
        expect(len(keepers) == 1 and vmms(stack), "the keeper runs the person's VM", keepers)
        restarts = stack.inspect(stack.container)["RestartCount"]
        run("docker", "exec", "-u", "0", stack.container, "kill", "-KILL", str(keepers[0]), check=False)

        def again():
            info = stack.inspect(stack.container)
            return info["RestartCount"] > restarts and info["State"]["Running"]
        eventually(again, "the Locus container to start again", timeout_s=60)
        stack.published()
        # The keeper is the one child of the container's PID 1, docker-init (docker-compose.yml's `init: true`), which
        # exits as its child does: the kernel then ends the container's PID namespace and every VMM in it, as the
        # stage's parent-death signal ends each VMM with its keeper besides (keeper_killed). The next life's keeper
        # ends any group the last one left before it admits anything, and says so only where it cannot.
        logs = stack.logs()
        expect(not vmms(stack) and group_gone(stack, record["uid"]) and not EARLIER_GROUPS_SAID.search(logs),
               "before the next life admits anything no VMM of the last one runs and the VM's group is gone, and its "
               "keeper meets no group of the last it cannot end", [vmms(stack), logs[-3000:]])
        c = synced(stack, [(owner, [vm_probe()])])
        later = boot_id(c, owner, "b")
        kept = sh(c, owner, 'cat "$HOME/kept.txt"', "b")
        machines = vmms(stack)
        expect(later != first and kept["stdout"] == "kept\n" and list(machines.values()) == [record["uid"]],
               "the person's next session boots a VM of their disk's uid and finds what the last one wrote",
               [first, later, kept, machines])
        after, _folder = image_stat(stack, owner)
        expect(after["inode"] == stat["inode"] and disk_record(stack, owner) == record,
               "it runs on the same image, its record as it was", [stat, after])
    finally:
        stack.down()


MEASURED_ROW = "mcp_vm-measured"


def largest():
    """The largest generation a set may be, cheaply made: four packs of two random files each, every file under the
    store's bound on one file and every pack under its own, all of them under the set's (packview's MaxFileBytes,
    MaxPackBytes and MaxSetBytes)."""
    return {f"big{i}/{name}": (os.urandom(size), False)
            for i in range(4) for name, size in (("one.bin", 19_000_000), ("two.bin", 13_000_000))}


def set_digest(files):
    """A set digest as the control plane names one, here of the files' own digests (packs.py's digest_of holds every
    byte twice over, which a large set makes costly)."""
    return "sha256:" + hashlib.sha256(json.dumps(sorted(
        (path, hashlib.sha256(data).hexdigest()) for path, (data, _x) in files.items())).encode()).hexdigest()


def allocated(stack, owner):
    """The image's allocated size, as du reads it, in MiB."""
    return int(read_output(stack.observe(f"du -k {image_of(owner)}"), "the image's du").split()[0]) // 1024


def vmm_process(stack):
    """The one VMM's pid and its API socket, from its command line."""
    found = [p for p in stack.processes() if p["cmd"].split()[:1] == [FIRECRACKER]]
    expect(len(found) == 1, "one VMM runs", found)
    argv = found[0]["cmd"].split()
    return found[0]["pid"], argv[argv.index("--api-sock") + 1]


def vmm_resident(stack, pid):
    """The VMM process's resident memory, from its status: VmRSS and its anonymous, file and shared parts, in MiB."""
    text = read_output(stack.observe(f"grep -E '^(VmRSS|RssAnon|RssFile|RssShmem):' /proc/{pid}/status"),
                       f"the VMM {pid}'s status")
    return {line.split(":")[0]: int(line.split()[1]) // 1024 for line in text.splitlines()}


def vmm_config(stack, api):
    """The VMM's configuration as the keeper made it, read from the VMM's own API: the guest's processors and memory
    (`machine-config`) and its kernel's command line (`boot-source`) among it."""
    text = read_output(stack.observe(f"curl -sS --max-time 5 --unix-socket {api} http://localhost/vm/config"),
                       "the VMM's configuration")
    return json.loads(text)


def vm_gateway(stack, api):
    """The VM's gateway, the guard's end of the VM's route, as the keeper gives it to the guest's kernel: the
    `cyfr.net=<inner>,<gateway>` of its command line (internal/vm's NetArg)."""
    args = vmm_config(stack, api)["boot-source"]["boot_args"]
    found = re.search(r"(?:^| )cyfr\.net=[0-9.]+,([0-9.]+)(?: |$)", args)
    if not found:
        sys.exit(f"FAIL: the guest's command line names no route: {args!r}")
    return found.group(1)


def idle_minute(c, owner):
    """A minute in which the owner holds no session, its lease renewed so its programs stay synced."""
    end = time.monotonic() + 60
    while time.monotonic() < end:
        expect(c.renew([owner], lease_ms=60_000)[0] == 200, "the idle owner is renewed")
        time.sleep(min(20, max(0, end - time.monotonic())))  # sleep-ok: the measure is of an idle minute


def memory_line(stack, uid, pid):
    """The VMM's resident memory and its group's memory.current and reading, as printed."""
    current, reading = vmm_memory(stack, uid)
    rss = vmm_resident(stack, pid)
    return (f"VmRSS {rss['VmRSS']} MiB (anonymous {rss['RssAnon']}, file {rss['RssFile']}, shared "
            f"{rss['RssShmem']}), its group's memory.current {current / MIB:.1f} MiB and reading "
            f"{reading / MIB:.1f} MiB")


def measured_at(stack, c, owner, put_largest):
    """A person's first boot and an idle minute at the pool the stack's keeper runs, printed: the guest's memory as the
    keeper gave it, the VMM's resident memory and its group's, the image's allocated size and the guard's peak; with
    `put_largest`, the VMM's memory once a session binds the largest generation too. `c` is the controller that
    greeted the stack's keeper."""
    pool = [line for line in stack.logs().splitlines() if "the pool: budget" in line][-1].split("info: ", 1)[-1]
    status, answer, _ = c.sync(owner, [vm_probe(), vm_probe("packed", packs=True)], lease_ms=60_000)
    expect(status == 200, f"{owner['athanor']}'s programs are synced", answer)
    guest = int(sh(c, owner, "awk '/^MemTotal:/ {print $2}' /proc/meminfo", "a")["stdout"].strip()) // 1024
    uid = disk_record(stack, owner)["uid"]
    pid, api = vmm_process(stack)
    config = vmm_config(stack, api)["machine-config"]
    booted = memory_line(stack, uid, pid)
    disk = allocated(stack, owner)
    peak = read_output(stack.guard_exec("cat /sys/fs/cgroup/memory.peak /sys/fs/cgroup/memory.current"),
                       "the guard's memory").split()
    session = c.mcp(owner, "probe", key="a", home_id=row_of(owner)).session
    expect(c.close(owner, session)[0] == 200, "the session is closed, its VM left idle")
    idle_minute(c, owner)
    expect(vmm_process(stack)[0] == pid, "the idle VM runs on through its idle minute")
    idle = memory_line(stack, uid, pid)
    idle_disk = allocated(stack, owner)
    print(f"measured, {pool}: the keeper gave the guest {config['mem_size_mib']} MiB and "
          f"{config['vcpu_count']} processors (its MemTotal {guest} MiB). After the person's first boot, with one "
          f"session: {booted}; the image {disk} MiB allocated; the guard's memory.peak {int(peak[0]) / MIB:.1f} MiB "
          f"(memory.current {int(peak[1]) / MIB:.1f} MiB) with one VM routed. After an idle minute with no "
          f"session: {idle}; the image {idle_disk} MiB allocated", flush=True)
    if not put_largest:
        return
    files = largest()
    total = sum(len(d) for d, _x in files.values())
    put_at = time.monotonic()
    state, puts, client = packs.started(c, owner, "big", MEASURED_ROW, set_digest(files), program="packed",
                                        files=files)
    expect(state == "missing" and puts[-1][1]["state"] == "held", "the largest generation is put", puts[-1:])
    held = packs.run_in(client, f"du -sb {SCROLLS}")
    took = time.monotonic() - put_at
    expect(held["status"] == 0 and int(held["stdout"].split()[0]) >= total,
           "a session in the VM binds the largest generation", held)
    time.sleep(3)  # sleep-ok: the group's counters settle a reading's batch after the put
    print(f"measured, {pool}: with a session binding a generation of {len(files)} files, {total / MIB:.1f} MiB in "
          f"4 packs, put and started in {took:.1f} s: {memory_line(stack, uid, pid)}", flush=True)


# The guest sizes a person's VM's own cost is measured at: the keeper gives each guest its rest, which these pools
# make on this machine; none is the shipped sizing, the largest guest it gives.
COST_SIZES = (2560 * MIB, 8192 * MIB, None)
COST_RUNS = 3
# What of the VMM group's memory.stat each reading takes, where the kernel has it.
COST_STAT = ("anon", "file", "kernel", "percpu", "kernel_stack", "pagetables")


def cost_reading(stack, uid, pid):
    """The VMM group's memory.current and its memory.stat's parts (COST_STAT, those the kernel has), and the VMM
    process's VmRSS, in bytes."""
    group = vmm_group(uid)
    current = int(read_output(stack.exec(f"cat {group}/memory.current"), f"{group}/memory.current").strip())
    stat = imagesuite.read_counters(stack.exec(f"cat {group}/memory.stat"), ("anon", "file", "kernel"),
                                    f"{group}/memory.stat")
    rss = vmm_resident(stack, pid)["VmRSS"] * MIB
    return {"current": current, **{name: stat[name] for name in COST_STAT if name in stat}, "vmrss": rss}


def vm_cost(stack, c, owner, size, run_number):
    """One fresh VM's own cost at the stack's pool: (a) its first session answered and then nothing asked for 20 s,
    (b) its session answering, (c) that session released; then the VMM is killed, so the next VM runs alone. Prints
    each reading as a raw line and answers them with the guest's MemTotal and the keeper's configuration. `c` is the
    controller that greeted the stack's keeper."""
    status, answer, _ = c.sync(owner, [vm_probe()], lease_ms=60_000)
    expect(status == 200, f"{owner['athanor']}'s programs are synced", answer)
    expect(sh(c, owner, "echo answered", "a")["stdout"] == "answered\n", "the person's first session answers")
    uid = disk_record(stack, owner)["uid"]
    pid, api = vmm_process(stack)
    config = vmm_config(stack, api)["machine-config"]
    time.sleep(20)  # sleep-ok: reading (a) is of the VM at rest, nothing asked of it for 20 s
    at_rest = cost_reading(stack, uid, pid)
    meminfo = sh(c, owner, "cat /proc/meminfo", "a")["stdout"]
    answering = cost_reading(stack, uid, pid)
    mem_total = int(next(line.split()[1] for line in meminfo.splitlines() if line.startswith("MemTotal:"))) * 1024
    released = stack.logs().count(SESSION_RELEASED_SAID)
    session = c.mcp(owner, "probe", key="a", home_id=row_of(owner)).session
    expect(c.close(owner, session)[0] == 200, "the session is closed")
    eventually(lambda: stack.logs().count(SESSION_RELEASED_SAID) > released, "the session's release")
    time.sleep(3)  # sleep-ok: the guest reports the pages its session freed within its reporting delay
    after = cost_reading(stack, uid, pid)
    readings = {"size": size, "run": run_number, "mem_size_mib": config["mem_size_mib"],
                "vcpu_count": config["vcpu_count"], "mem_total": mem_total, "a": at_rest, "b": answering, "c": after}
    print("measured raw " + json.dumps(readings, sort_keys=True), flush=True)
    print("measured raw meminfo " + json.dumps({"size": size, "run": run_number, "meminfo": meminfo}), flush=True)
    run("docker", "exec", "-u", "0", stack.container, "kill", "-KILL", str(pid), check=False)
    eventually(lambda: not vmms(stack) and group_gone(stack, uid), "the measured VM to be released", timeout_s=30)
    return readings


def cost_table(rows):
    """The cost table: each guest size's range, min to max over its runs, of MemTotal and each reading's
    memory.current, anon and kernel, in MiB."""
    def spread(values):
        low, high = min(values) / MIB, max(values) / MIB
        return f"{low:.0f}" if round(low) == round(high) else f"{low:.0f}-{high:.0f}"

    lines = ["guest size (rest, MemoryMiB) | MemTotal | (a) at rest: current/anon/kernel | "
             "(b) answering: current/anon/kernel | (c) released: current/anon/kernel   [MiB, min-max of "
             f"{COST_RUNS} fresh VMs]"]
    for size in dict.fromkeys(r["size"] for r in rows):
        runs = [r for r in rows if r["size"] == size]
        cells = [f"{size // MIB} MiB ({'/'.join(sorted({str(r['mem_size_mib']) for r in runs}))})",
                 spread([r["mem_total"] for r in runs])]
        for reading in "abc":
            cells.append("/".join(spread([r[reading][part] for r in runs]) for part in ("current", "anon", "kernel")))
        lines.append(" | ".join(cells))
    return "\n".join(lines)


def measurements(image):
    """A person's VM's costs, printed: a first boot and an idle minute beside the largest generation at the first
    guest size, and the VM's own cost at each of COST_SIZES, the shipped sizing's rest the last."""
    stack = wall_stack("measured", image)
    rows = []
    try:
        for index, work in enumerate(COST_SIZES):
            if index:
                # The guard's check fails once a person's VM has been routed, so compose starts no keeper behind it
                # again: the guard is started afresh with the keeper at the next size, on the same volumes, where
                # the image's programs' device stands.
                stack.compose("stop", SERVICE)
                stack.compose("up", "--detach", "--no-build", "--force-recreate", "--no-deps", GUARD)
            up_wall(stack, work)
            c = synced(stack, [])
            pool = [line for line in stack.logs().splitlines() if "the pool: budget" in line][-1]
            rest = int(re.search(r"rest (\d+) MiB", pool).group(1)) * MIB
            print(f"measured: {pool.split('info: ', 1)[-1]}", flush=True)
            if index == 0:
                measured_at(stack, c, owner_of("vm-measured"), True)
                pid, _api = vmm_process(stack)
                run("docker", "exec", "-u", "0", stack.container, "kill", "-KILL", str(pid), check=False)
                eventually(lambda: not vmms(stack), "the first measured VM to end", timeout_s=30)
            for number in range(1, COST_RUNS + 1):
                rows.append(vm_cost(stack, c, owner_of(f"vm-cost-{rest // MIB}-{number}"), rest, number))
        print("measured, a person's VM's own cost by its guest's size:\n" + cost_table(rows), flush=True)
    finally:
        stack.down()


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
        expect("/etc/hostname" not in paths, "the device holds no Docker-bound /etc/hostname")
        # The guest's own (package vm's guestFiles): its spaces' resolver is
        # their own name sockets', and Docker's lines are not carried in.
        resolver = device_file(image, guest, first["device"], "/etc/resolv.conf")
        expect(resolver.splitlines()[:1] == ["nameserver 127.0.0.11"] and "Docker" not in resolver,
               "the device's /etc/resolv.conf is the guest's own, its spaces' resolver at 127.0.0.11", repr(resolver))
        hosts = device_file(image, guest, first["device"], "/etc/hosts")
        expect(hosts.splitlines()[:1] == ["127.0.0.1\tlocalhost"] and len(hosts.splitlines()) == 2,
               "the device's /etc/hosts is the guest's own, the loopback's alone", repr(hosts))

        code, second, stderr = guest_check(stack, image, kept, guest, extra=("--beside",))
        booted(code, second, stderr, "the second start")
        expect(second["device_made"] is False and second["device"] == first["device"],
               "the second start finds the device and makes none", second)
        expect(second["boot_id"] != first["boot_id"], "the second start boots a new guest", second)
        beside = second.get("beside") or {}
        expect(beside.get("uid", 0) > 0 and beside.get("uid") != second["uid"],
               "the machine beside runs under a uid of its own", f"{beside}, the first's {second['uid']}")
        expect(beside.get("folder", "").startswith(f"{MACHINES}/{beside.get('uid')}-") and beside["folder"] != second["folder"],
               "the machine beside has a folder of its own", beside)
        expect(BOOT_ID.match(beside.get("boot_id", "")) and beside["boot_id"] != second["boot_id"],
               "the machine beside is a guest of its own", beside)
        expect(beside.get("end") == "acknowledged",
               "the machine beside ends acknowledged, and the first answered for its space after it", beside)

        keeper_killed(stack, image, kept, guest, project)

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
    print("ok: a person's machine boots from the image's programs, as the keeper makes them", flush=True)

    for case in (disk_and_boot, boot_identity, routes_and_names, packs_in_vm, scratch_in_vm, ledger_one_vm,
                 ledger_pressure, vmm_killed, folders_in_vm, guard_lost_at_start, keeper_lost, measurements):
        print(f"== {case.__name__}: {case.__doc__.split(chr(10))[0]}", flush=True)
        case(image)
    print("PASS: a person's machine boots from the image's programs, and a person's sessions run in their own VM")


if __name__ == "__main__":
    imagesuite.stop_on_signals()
    main()
