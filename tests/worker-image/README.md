<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 CYFR Works Inc. -->

# worker image tests

These suites run the Opus image (`Dockerfile.opus`) as `docker-compose.yml`'s
`opus` service, layered with `compose.worker.yml` for the image under test, a
loopback port and the pool settings a case chooses, against a scripted
control plane on this machine. They read what only the image shows: the
runners' processes, uids, homes, memory groups and memory, and the
container's CPU and log. CI runs `runners.py`, which runs `memory.py`'s
cases, and `canary.py` in the `worker-image` job of
`.github/workflows/test.yml`; `namespace.py` and `memory.py --measure`
run by hand.

| Suite | What it shows |
|---|---|
| `runners.py` | runners ended at their bounds, settlement and cleanup, the relay, pinned egress, attached requests and the shipped model catalysts' requests, the queue age of a fresh runner, and `memory.py`'s cases |
| `memory.py` | every runner in a memory group of its own at the service's bound, and no runner at all without `writable-cgroups=true`; `--measure` prints each workload's group peak |
| `namespace.py` | each runner in a user and network namespace of its own, with no route out |
| `canary.py` | the credential canary: a credential CYFR attaches to a guest's request reaches neither the runner nor the worker service |

The suites share `stack.py` (the service under compose, and the
observer that reads inside the container), `control_plane.py` (CYFR's host
API as the tests script it) and `worker_auth.py` (`Prima.WorkerAuth`, held
to `tests/fixtures/`' vectors). `hog.wat` is the memory case's guest, built
to `hog.wasm` by `build.sh`, whose digests `memory.py` records.

## Running

```sh
docker build -f Dockerfile.opus -t cyfr-opus:test .
python3 tests/worker-image/runners.py cyfr-opus:test
python3 tests/worker-image/canary.py cyfr-opus:test
```

On the verification host each runs alone, through `scripts/heavy-check.sh`.
They need Docker Engine 28 or later with Compose on a cgroup v2 host that
allows unprivileged user namespaces (`docker-compose.yml`'s `opus` service
says why), and Python 3. Each case prints an `ok:` line per assertion and
stops at the first `FAIL:`.

## The credential canary

`canary.py`'s scenario `credential_canary` runs the hostile
`credential_canary` catalyst
(`apps/opus/test/support/test_wasm/hostile/`), which names its connection
on one request to an upstream on this machine that reflects the request's
headers and body, asks its vault for the attached field, and writes
everything it saw to an event and its output. The control plane attaches
a canary value as CYFR does and masks it out of the answer. While the
attempt's close is held, the observer reads the runner's process memory
(`/proc/PID/mem`, every readable mapping), the worker service's, and the
runner's tmpfs home; the attempt is then killed so the service reports the
runner's exit. The canary must be in none of these, nor in the container's
log, the exit report, the attach answer, the event, the output or anything
sent to the control plane, and must be in the upstream's log.

Its positive control plants another canary in a disclosed field on
another athanor's runner, which its guest reads and writes out, and the
same dump must find it, so a clean dump reads what it claims to.
