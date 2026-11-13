# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Every application's test seams in the running release, evaluated inside
# it by `bin/cyfr rpc` (tests/release-boot/boot.sh): a release is compiled
# without the test permission (`:prima, :test_seams_permitted`), so no
# setting it is given reaches a seam (`Prima.TestSeam.value/2`, which
# compiles the permission into each caller). The permission, and every
# seam's key a check below reads, is set here at runtime, as `sys.config`
# or `ERL_AFLAGS` could set them, and the release must answer as it ships:
#
#   - Arca, Sanctum and the host were each compiled without the
#     permission (each records it in its own compile-time environment, so
#     a release handed another value refuses to boot);
#   - Arca: its member still holds its control-plane slot, its control
#     plane still writes on its own pool, its SQLite writers still take
#     write turns, the decision log keeps its shipped budget, and a
#     bookkeeping row still goes to the write-behind;
#   - the host: each switched process, which this release runs, is
#     started again and answers that it already runs: its start never read
#     its switch, which would have answered `:ignore`;
#   - Sanctum: the WorkOS sign-in keeps https://api.workos.com, a company
#     sign-in's authorization URL comes from no injected OIDC client, the
#     directory client takes no suite options, the OAuth presets take no
#     scripted provider and the caller memo keeps its 2 s bound; an
#     issuance refuses a fixture's generation snapshot; and
#     `Sanctum.Tenancy`'s compiled code names no resolver override.
#
# Seams with no cheap door are held elsewhere: the namespace cache's
# lifetime needs a person's row, so the headless case of
# tests/release-boot/boot.sh holds it; the boot's own reads (the gate, the
# database checks, the recovery and the status watch) are read before
# anything can be set here, so its restores case boots a release handed
# the database-checks switch; whether a fill runs inline
# (`:provisioning_inline`) needs a registry that never answers, so
# apps/cyfr/test/sanctum/provisioning_test.exs holds it with
# `Compendium.Provisioning` compiled without the permission.
# apps/cyfr/test/cyfr/test_seams_test.exs holds every read of a
# seam's key inside the gate.
#
# Every check runs; a release that fails any raises naming each, and one
# that passes them all prints the one line `CYFR_TEST_SEAMS=ok`. Every key
# is left as it was.

failures = :counters.new(1, [])
failed = :ets.new(:cyfr_release_proof_failures, [:public, :bag])

check = fn
  true, _what ->
    :ok

  false, what ->
    :counters.add(failures, 1, 1)
    :ets.insert(failed, {:failed, what})
end

reads = :counters.new(1, [])

# A seam's value names this probe, so a read of it is seen where it lands.
defmodule CyfrReleaseProof.Seam do
  def counter, do: :persistent_term.get({__MODULE__, :reads})
  def preset(_hint), do: hit(nil)
  def authorize_url(_request), do: hit({:ok, "https://seam.invalid/oidc"})
  def hit(answer), do: tap(answer, fn _ -> :counters.add(counter(), 1, 1) end)
end

:persistent_term.put({CyfrReleaseProof.Seam, :reads}, reads)

switched = [
  retention_scheduler_enabled: Cyfr.RetentionScheduler,
  external_server_reconciler_enabled: Emissary.External.Reconciler,
  schedule_notes_enabled: Aqua.ScheduleNotes,
  crew_delivery_enabled: Aqua.Crew,
  execution_sweeper_enabled: Opus.Sweeper,
  execution_archive_watch_enabled: Opus.ArchiveWatch,
  worker_watch_enabled: Opus.WorkerWatch,
  cron_scheduler_enabled: Opus.Schedules.Scheduler
]

handed =
  [
    {:prima, :test_seams_permitted, true},
    {:arca, :control_plane_claim_enabled, false},
    {:arca, :control_plane_pool, false},
    {:arca, :write_turn, false},
    {:arca, :decision_log_budget_ms, 1},
    {:arca, :record_sink_inline, true},
    {:sanctum, :workos_api_url, "https://seam.invalid"},
    {:sanctum, :workos, %{client_id: "client", organization: "org"}},
    {:sanctum, :oidc_reauth_client, CyfrReleaseProof.Seam},
    {:sanctum, :directory_client, [not_an_option: true]},
    {:sanctum, :scripted_oauth_provider, CyfrReleaseProof.Seam},
    {:sanctum, :caller_memo_ttl_ms, 3_600_000}
  ] ++ for {key, _module} <- switched, do: {:cyfr, key, false}

saved = for {app, key, _value} <- handed, do: {app, key, Application.fetch_env(app, key)}

try do
  for {app, key, value} <- handed, do: Application.put_env(app, key, value)

  for app <- [:arca, :sanctum, :cyfr] do
    {:ok, [{:application, ^app, spec}]} =
      :file.consult(Path.join(:code.lib_dir(app), "ebin/#{app}.app"))

    compiled = Keyword.get(spec, :compile_env, [])

    check.(
      {:prima, [:test_seams_permitted], :error} in compiled,
      "compiled #{app} with the test permission: #{inspect(Enum.filter(compiled, &(elem(&1, 0) == :prima)))}"
    )
  end

  # Arca.
  check.(Arca.ControlPlane.claimed?(), "read :control_plane_claim_enabled: no claimant runs")

  check.(
    match?({:ok, %{owner: _}}, Arca.ControlPlane.member_slot()),
    "holds no control-plane slot: #{inspect(Arca.ControlPlane.member_slot())}"
  )

  check.(Arca.ControlPlane.own_pool?(), "read :control_plane_pool: no pool of its own")
  check.(Arca.ControlPlane.children() != [], "would start the control plane without its pool")

  check.(
    is_pid(Process.whereis(:arca_control_plane_pool)),
    "runs no control-plane pool"
  )

  check.(Arca.WriteTurn.enabled?(), "read :write_turn: its writers take no turns")

  if Arca.Repo.__adapter__() == Ecto.Adapters.SQLite3 do
    turn =
      Arca.Repo.locking_transaction(fn -> Arca.WriteTurn.holding?() end, write_turn: :audit)

    check.(turn == {:ok, true}, "wrote without a write turn: #{inspect(turn)}")
  end

  check.(Arca.DecisionLog.budget_ms() == 500, "read :decision_log_budget_ms")

  # A bookkeeping row still goes to the write-behind, never written in its
  # caller: with the sink held, it waits in the sink's mailbox. The row
  # names no vault entry, so its write, once the sink runs again, touches
  # nothing.
  sink = Process.whereis(Arca.RecordSink)
  check.(is_pid(sink), "runs no record sink")

  if is_pid(sink) do
    :sys.suspend(sink)

    try do
      {:message_queue_len, waiting} = Process.info(sink, :message_queue_len)
      :ok = Arca.RecordSink.enqueue({:vault_touch, "ath_release_proof", "ent_release_proof"})

      check.(
        Process.info(sink, :message_queue_len) == {:message_queue_len, waiting + 1},
        "read :record_sink_inline: wrote a bookkeeping row in its caller"
      )
    after
      :sys.resume(sink)
    end
  end

  # The host.
  for {key, module} <- switched do
    running = Process.whereis(module)
    check.(is_pid(running), "runs no #{inspect(module)}")

    check.(
      is_pid(running) and module.start_link([]) == {:error, {:already_started, running}},
      "read #{inspect(key)} where #{inspect(module)} starts"
    )
  end

  # Sanctum.
  {:ok, url} =
    Sanctum.Auth.WorkOS.authorize_url(%{redirect_uri: "https://example.com/callback"}, "state")

  check.(URI.parse(url).host == "api.workos.com", "sent the WorkOS sign-in to #{url}")

  # The shipped client asks this release's own issuer settings, which name
  # none here: it answers unavailable, and never the injected client's URL.
  oidc =
    Sanctum.Auth.OIDC.authorize_url(
      %{redirect_uri: "https://example.com/callback", nonce: "nonce", pkce_verifier: "verifier"},
      "state"
    )

  check.(
    oidc != {:ok, "https://seam.invalid/oidc"},
    "took the injected OIDC client: #{inspect(oidc)}"
  )

  check.(
    Sanctum.Directory.Client.log("not-an-identifier", "https://directory.invalid") ==
      {:error, :invalid_locator},
    "took the suite's directory options"
  )

  check.(Sanctum.Vault.OAuth.preset("cyfr-release-proof") == nil, "read a scripted OAuth preset")

  validated = DateTime.add(DateTime.utc_now(), -10, :second)

  check.(
    not Sanctum.Caller.fresh?(%Sanctum.Context{validated_at: validated}),
    "kept a context fresh past the shipped 2 s memo"
  )

  check.(
    Sanctum.Issuance.expectation(%Sanctum.Context{user_id: "usr_release_proof"},
      generation_snapshot: %{
        user_id: "usr_release_proof",
        user_generation: 1,
        athanor_id: nil,
        athanor_generation: nil
      }
    ) == {:error, :missing_generation},
    "issued under a fixture's generation snapshot"
  )

  {:ok, {Sanctum.Tenancy, [atoms: atoms]}} =
    :beam_lib.chunks(:code.which(Sanctum.Tenancy), [:atoms])

  check.(
    not Enum.any?(atoms, fn {_number, atom} -> atom == :tenancy_resolver_override end),
    "compiled the tenancy resolver override in"
  )

  check.(:counters.get(reads, 1) == 0, "read a seam the probe set")
after
  for {app, key, value} <- saved do
    case value do
      {:ok, value} -> Application.put_env(app, key, value)
      :error -> Application.delete_env(app, key)
    end
  end
end

if :counters.get(failures, 1) > 0 do
  found = for {:failed, what} <- :ets.lookup(failed, :failed), do: "  - " <> what

  raise "a release built without the test permission:\n" <> Enum.join(found, "\n")
end

IO.puts("CYFR_TEST_SEAMS=ok")
