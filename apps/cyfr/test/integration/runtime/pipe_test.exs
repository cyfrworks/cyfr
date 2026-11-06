# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.PipeTest do
  @moduledoc """
  A catalyst's program pipe, end to end: the hostile `pipe_probe`
  (`test_wasm/hostile/` of the runtime's suite) run by the runtime in a
  runner of its own, over the suite's wire (`Cyfr.Test.TwoServices`),
  through CYFR's host (`Opus.Host.Pipe`) and its programs controller
  (`Opus.Programs`) to a real backends service of Locus on a loopback port,
  which runs a `pipe` row's program, `cat`, through the test environment's
  launcher (`Locus.DirectLauncher`) in a login entry's kept home.

  The probe opens its login need `coder`, sends a line, reads the lines
  past 0 and closes. Bound by its consent to a login entry for the row, the
  line comes back from `cat`; a component that declares no such need, or
  whose need's binding mounts another program, is refused `denied` and
  opens nothing; once the entry is revoked, the open is refused
  `setup_required` and opens nothing.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Test.{ScriptedBackends, TwoServices}
  alias Sanctum.Consent.{Commit, Plan}

  # Locus is a sibling application: its backends service is the suite's
  # here, never CYFR's own code's.
  @compile {:no_warn_undefined, [Locus.Backends, Locus.Backends.Owners, Locus.Backends.Service]}

  @moduletag timeout: 300_000

  @probe Path.expand(
           "../../../../locus/test/support/runtime/test_wasm/hostile/pipe_probe.wasm",
           __DIR__
         )

  @key :crypto.strong_rand_bytes(32)
  @program "cat-pipe"
  # The service runs a row's command with the open's arguments after it
  # (`"$@"`); `cat` takes none of the probe's.
  @command "exec cat; :"

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    TwoServices.watch!()

    run_dir = Path.join(System.tmp_dir!(), "pipe_e2e_#{System.unique_integer([:positive])}")
    kept = Path.join(run_dir, "kept")
    File.mkdir_p!(kept)
    Prima.Test.Env.put_app_env(:arca, :base_path, Path.join(run_dir, "arca"))

    {ctx, _user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))

    on_exit(fn ->
      Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id)
      File.rm_rf!(run_dir)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()
    Sanctum.TestContext.ready!(ctx.athanor_id)
    serve_backends!(kept)
    {:ok, ctx: ctx, kept: kept}
  end

  # A backends service of Locus on a loopback port, its sessions run by the
  # test launcher with kept homes under `kept`, and the programs
  # controller's local box pointed at it.
  defp serve_backends!(kept) do
    sessions = start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: :pipe_sessions)

    owners =
      start_supervised!(
        {Locus.Backends.Owners,
         [
           launcher: Locus.DirectLauncher,
           launcher_server: [kept_root: kept],
           supervisor: sessions,
           memory_bytes: 1_073_741_824,
           stop_grace_ms: 100,
           session_opts: [release_timeout_ms: 5_000]
         ]},
        id: :pipe_owners
      )

    listener =
      start_supervised!(
        Locus.Backends.listener(
          plug: {Locus.Backends.Service, owners: owners, key: @key},
          ip: {127, 0, 0, 1},
          port: 0,
          startup_log: false
        ),
        id: :pipe_listener
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)

    ScriptedBackends.supervise_controller(
      url: "http://127.0.0.1:#{port}",
      root: @key,
      tick_ms: 3_600_000
    )
  end

  # ---------------------------------------------------------------------------
  # Seeding
  # ---------------------------------------------------------------------------

  # The `pipe` row of the athanor, keeping its home, whose program is `cat`.
  defp row!(ctx) do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: @program,
        transport: "pipe",
        url: nil,
        home: "kept",
        config_json:
          Jason.encode!(%{
            "backends" => [%{"name" => "cat", "command" => @command, "env" => %{}}]
          })
      })

    row
  end

  defp login!(ctx) do
    {:ok, entry} =
      Sanctum.TestContext.create_signed_in_login(ctx, %{
        name: "cat-login-#{System.unique_integer([:positive])}",
        program: @program
      })

    entry
  end

  # The probe, published as a component of the person's own with `needs`.
  defp publish_probe!(ctx, needs) do
    name = "pipe-probe-#{System.unique_integer([:positive])}"
    manifest = %{"name" => name, "version" => "1.0.0", "type" => "catalyst", "needs" => needs}

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@probe), %{
        name: name,
        version: "1.0.0",
        type: "catalyst",
        manifest: Jason.encode!(manifest)
      })

    "catalyst:local." <> name
  end

  defp login_need(program),
    do: %{"type" => "login", "program" => program, "reason" => "to run #{program}"}

  # `ref`'s owner consent, binding `bindings`, through the consent walk.
  defp consent!(ctx, ref, bindings) do
    {:ok, plan} = Plan.plan(ctx, %{ref: ref})
    decisions = %{ref: ref, bindings: bindings}
    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, %{profile_id: profile_id}} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    profile_id
  end

  # A root of `ref` under its owner consent, run by the runtime: what the
  # guest answered as its runner closed the attempt.
  defp run!(ctx, ref, line) do
    id = Prima.UUID7.execution_id()
    {:ok, _} = Opus.run_root(ctx, :default, ref <> ":1.0.0", %{"line" => line}, execution_id: id)
    TwoServices.settled!()

    assert [%{args: %{"outcome" => %{"output" => %{"status" => 200, "data" => data}}}}] =
             TwoServices.calls(:complete, id)

    data
  end

  # ---------------------------------------------------------------------------
  # Cases
  # ---------------------------------------------------------------------------

  test "a catalyst bound to a login entry round-trips a line through cat in the entry's home",
       %{ctx: ctx, kept: kept} do
    row!(ctx)
    entry = login!(ctx)
    ref = publish_probe!(ctx, %{"coder" => login_need(@program)})
    consent!(ctx, ref, [%{need: "coder", entry_id: entry.id}])

    assert %{
             "open" => "ok",
             "session" => session,
             "resumed" => false,
             "send" => "ok",
             "recv" => "ok",
             "count" => 1,
             "dropped" => 0,
             "line" => "hello through the pipe",
             "running" => true,
             "close" => "ok"
           } = run!(ctx, ref, "hello through the pipe")

    assert is_binary(session)
    assert File.dir?(Path.join(kept, entry.id)), "the program ran in the entry's kept home"

    # Closed by the guest: nothing of it is held, and its owner let go.
    assert Opus.Programs.mounts() == []

    # The next run opens its key afresh.
    assert %{"open" => "ok", "resumed" => false, "line" => "again"} = run!(ctx, ref, "again")
  end

  test "a catalyst declaring no login need is refused denied, and opens nothing", %{ctx: ctx} do
    row!(ctx)
    ref = publish_probe!(ctx, %{})
    consent!(ctx, ref, [])

    assert %{"open" => "denied"} = data = run!(ctx, ref, "hello")
    refute Map.has_key?(data, "send")
    assert Opus.Programs.mounts() == []
  end

  test "a need whose binding mounts another program is refused denied", %{ctx: ctx} do
    row!(ctx)
    entry = login!(ctx)

    # `coder` names a program of its own; the consent binds the other need,
    # whose entry mounts the row.
    ref =
      publish_probe!(ctx, %{
        "coder" => login_need("elsewhere"),
        "aux" => login_need(@program)
      })

    consent!(ctx, ref, [%{need: "aux", entry_id: entry.id}])

    assert %{"open" => "denied"} = run!(ctx, ref, "hello")
    assert Opus.Programs.mounts() == []
  end

  test "an open that does not read consumes no once binding", %{ctx: ctx} do
    row!(ctx)
    entry = login!(ctx)
    ref = publish_probe!(ctx, %{"coder" => login_need(@program)})
    consent!(ctx, ref, [%{need: "coder", entry_id: entry.id, lifetime: %{kind: "once"}}])

    # The probe is held at its own open; meanwhile its attempt asks again
    # with a key past the bound.
    wire = TwoServices.watch!()

    TwoServices.Wire.hold(wire, &(&1.callback == :pipe_open),
      holder: self(),
      once: true,
      notify: fn call, conn -> {:held_open, call, conn} end
    )

    id = Prima.UUID7.execution_id()

    running =
      Task.async(fn ->
        Opus.run_root(ctx, :default, ref <> ":1.0.0", %{"line" => "x"}, execution_id: id)
      end)

    assert_receive {:held_open, %{fields: fields}, conn}, 30_000

    caller = %{fields | nonce: "n_pipe_long_key"}
    long = String.duplicate("k", 257)

    assert {:error, {:guest_error, "invalid_request", _}} =
             Opus.Host.Pipe.open(caller, "coder", long, [])

    assert %{consumed_by_root: nil, lifetime_kind: "once"} = binding_row!(entry)

    # The binding stands: the probe's own open, let go, mounts it.
    TwoServices.release!(conn)
    assert {:ok, _} = Task.await(running, 60_000)
    TwoServices.settled!()

    assert [%{args: %{"outcome" => %{"output" => %{"data" => %{"open" => "ok"}}}}}] =
             TwoServices.calls(:complete, id)

    assert %{consumed_by_root: root} = binding_row!(entry)
    assert is_binary(root)
  end

  # The consent's binding row of `entry`.
  defp binding_row!(entry) do
    import Ecto.Query

    [row] =
      Arca.Repo.all(from r in Arca.Schemas.ConsentVaultRef, where: r.vault_entry_id == ^entry.id)

    row
  end

  test "once the login entry is revoked, an open is refused setup_required and opens nothing",
       %{ctx: ctx} do
    row!(ctx)
    entry = login!(ctx)
    ref = publish_probe!(ctx, %{"coder" => login_need(@program)})
    consent!(ctx, ref, [%{need: "coder", entry_id: entry.id}])
    assert %{"open" => "ok"} = run!(ctx, ref, "before")

    assert {:ok, _} = Sanctum.Vault.revoke(ctx, entry.id)

    assert %{"open" => "setup_required"} = run!(ctx, ref, "after")
    assert Opus.Programs.mounts() == []
  end
end
