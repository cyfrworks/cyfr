# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# :public_dns asks the public resolver and runs only when explicitly
# selected (`mix test --include public_dns`).
ExUnit.configure(exclude: [:public_dns])

# Opus's own suite runs with the contracts alone: no database and no
# control plane. Every host call a test makes goes to a scripted host
# (`Opus.Test.ScriptedHost`) served on a loopback port. The worker service
# the application starts is given the key that host derives for it, so its
# reports verify there, and a host URL nothing listens on; a test that
# needs the running service to reach a host points it at its own. Its
# listener binds port 0: a test that needs one starts its own and asks
# which port it was given.
#
# The service runs its runners as OS processes of their own (the `Direct`
# keeper), a pool of one kept ahead, since every test that points the
# service at its host restarts it and refills the pool. Runner code a test
# runs in this VM (the runtime, the handlers, `Opus.Runner`) runs on the
# engine the suite starts here (`Opus.Test.Engine`).
root = Opus.Test.ScriptedHost.root()
{:ok, worker_key} = Cyfr.WorkerAuth.worker_key(root, Opus.Test.ScriptedHost.service())

Application.put_env(:opus, :service_id, Opus.Test.ScriptedHost.service())
Application.put_env(:opus, :service_key, Base.encode16(worker_key, case: :lower))
Application.put_env(:opus, :host_url, "http://127.0.0.1:9")
Application.put_env(:opus, :bind, "127.0.0.1")
Application.put_env(:opus, :port, 0)
Application.put_env(:opus, :keeper, :direct)
Application.put_env(:opus, :pool_size, 1)

# The umbrella starts the application before this helper runs (and another
# suite in this VM may have given the service other credentials): the
# service is restarted so it holds these.
case Application.ensure_all_started(:opus) do
  {:ok, []} -> Opus.Test.ScriptedHost.restart_service!()
  {:ok, _started} -> :ok
end

:ok = Opus.Test.Engine.start!()

ExUnit.start()
