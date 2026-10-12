# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# The four logger-level restores (`application_test.exs`, `config_test.exs`)
# capture the live level, not the application environment, and put it back
# with `Logger.configure/1`, which writes the environment too. In an umbrella
# run the live level is :debug when this suite starts, even though the
# environment says :warning (`config/test.exs`). A locus test can precede a
# cyfr test in one VM, so the level set here, before any test runs, is the
# one the four restores put back.
Logger.configure(level: :warning)

# The build tests shell out to a real toolchain: `cargo component` for Rust
# components, `npm`/`node` for tinctures and for every test that needs a
# build to run at all. Tagged tests are excluded when the tool is not on
# PATH, so a machine without the Rust or Node toolchain runs the rest of
# the suite instead of failing tests that were never about the code under
# test. CI installs both, so nothing is skipped there.
excludes =
  Enum.concat(
    if(System.find_executable("cargo-component"), do: [], else: [:requires_cargo_component]),
    if(System.find_executable("node"), do: [], else: [:requires_node])
  )

if excludes != [] do
  IO.puts("locus: skipping #{inspect(excludes)} — toolchain not found on PATH")
  ExUnit.configure(exclude: excludes)
end

# The runtime's suites run with the contracts alone: no database and no
# control plane. Every host call a test makes goes to a scripted host
# (`Locus.Runtime.Test.ScriptedHost`) served on a loopback port. The worker
# service the application starts is given the key that host derives for
# it, so its reports verify there, and a host URL nothing listens on; a
# test that needs the running service to reach a host points it at its
# own. Its listener binds port 0: a test that needs one starts its own and
# asks which port it was given.
#
# The service runs its runners as OS processes of their own (the direct
# launcher's runner face), a pool of one kept ahead, since every test that
# points the service at its host restarts it and refills the pool. Runner
# code a test runs in this VM (the runtime, the handlers,
# `Locus.Runtime.Runner`) runs on the engine the suite starts here
# (`Locus.Runtime.Test.Engine`).
root = Locus.Runtime.Test.ScriptedHost.root()
{:ok, worker_key} = Prima.WorkerAuth.worker_key(root, Locus.Runtime.Test.ScriptedHost.service())

Locus.Runtime.Test.Env.merge(
  service_id: Locus.Runtime.Test.ScriptedHost.service(),
  service_key: Base.encode16(worker_key, case: :lower),
  host_url: "http://127.0.0.1:9",
  bind: "127.0.0.1",
  port: 0,
  keeper: :direct,
  pool_size: 1
)

# The umbrella starts the application before this helper runs (and another
# suite in this VM may have given the service other credentials): the
# runtime's service tree is restarted so it holds these.
case Application.ensure_all_started(:locus) do
  {:ok, []} -> Locus.Runtime.Test.ScriptedHost.restart_service!()
  {:ok, _started} -> :ok
end

:ok = Locus.Runtime.Test.Engine.start!()

ExUnit.start()
