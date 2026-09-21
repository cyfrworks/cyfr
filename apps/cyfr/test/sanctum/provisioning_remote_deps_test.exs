# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ProvisioningRemoteDepsTest do
  @moduledoc """
  A bundle whose required closure reaches a registry. Required dependency
  work is bounded per attempt: a registry that accepts a connection and
  never answers cannot hold an estate's fill open — the attempt stops
  within its budget, its claim settles failed with the timeout once it has
  stopped, the timeout is recorded on the row, and the next attempt
  resumes from what landed, a dependency below a partially installed
  remote component included. The seed sync heals a dependency an earlier
  attempt lost. An explicit retry or an install that meets an attempt in
  progress is told so, typed, without waiting; an attempt killed where it
  stands is released by its keeper.
  """
  use ExUnit.Case, async: false

  import Cyfr.Test.Wait

  alias Arca.ProvisioningClaims, as: Claims
  alias Compendium.Provisioning, as: Filler
  alias Sanctum.Provisioning
  alias Sanctum.Tenancy.Athanors

  # A registry of two fixture catalysts: `someone/catalysts/elsewhere`,
  # which the bundle requires, and `someone/catalysts/below`, which
  # `elsewhere` requires. Every manifest request tells the observer it
  # arrived, so a case can count who pulled. While the stall agent names a
  # repository, that repository's manifest request is accepted and held
  # until the agent stops naming it — a case that clears the stall lets
  # the pull it parked go on and finish.
  defmodule OCIRegistry do
    @behaviour Plug

    # The ceiling on a held request, well past any budget a case sets.
    @stall_ms :timer.minutes(2)
    @stall_poll_ms 25

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Plug.Conn{request_path: path} = conn, %{fixtures: fixtures, stall: stall} = opts) do
      case Regex.run(~r{^/v2/(.+)/(tags/list|manifests/[^/]+|blobs/[^/]+)$}, path) do
        [_, repo, "tags/list"] when is_map_key(fixtures, repo) ->
          json(conn, 200, %{"name" => repo, "tags" => ["1.0.0"]})

        [_, repo, "manifests/" <> _tag] when is_map_key(fixtures, repo) ->
          send(opts.observer, {:manifest, repo})

          if stalled?(stall, repo) do
            send(opts.observer, {:stalled, repo})
            hold(stall, repo, 0)
          end

          %{manifest: manifest, manifest_digest: digest} = fixtures[repo]

          conn
          |> Plug.Conn.put_resp_content_type(Compendium.OCI.Manifest.manifest_media_type())
          |> Plug.Conn.put_resp_header("docker-content-digest", digest)
          |> Plug.Conn.send_resp(200, manifest)

        [_, repo, "blobs/" <> digest] when is_map_key(fixtures, repo) ->
          case fixtures[repo].blobs[digest] do
            nil -> json(conn, 404, %{"errors" => [%{"code" => "BLOB_UNKNOWN"}]})
            bytes -> Plug.Conn.send_resp(conn, 200, bytes)
          end

        _ ->
          json(conn, 404, %{"errors" => [%{"code" => "NAME_UNKNOWN", "message" => path}]})
      end
    end

    defp hold(_stall, _repo, waited) when waited >= @stall_ms, do: :ok

    defp hold(stall, repo, waited) do
      if stalled?(stall, repo) do
        Process.sleep(@stall_poll_ms)
        hold(stall, repo, waited + @stall_poll_ms)
      else
        :ok
      end
    end

    # A case that ends while a request is held takes its stall agent with
    # it; the hold ends with the case rather than outliving it.
    defp stalled?(stall, repo) do
      Agent.get(stall, & &1) == repo
    catch
      :exit, _gone -> false
    end

    defp json(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end

  @repo_root Path.expand("../../../..", __DIR__)
  @wasm File.read!(Path.join(@repo_root, "apps/cyfr/test/support/test_wasm/math.wasm"))
  # The deadline a case exercising the CUT sets for itself. Every other
  # case here pulls for real against the fixture registry, so the setup
  # leaves a budget that cannot expire under suite load: a fill that
  # times out where the case expects it to finish is a flake, not a
  # finding, and the production budget is ten minutes
  # (`config/config.exs`) — nothing here may stand in for it.
  @cut_budget_ms 500
  @budget_ms 60_000

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_deadline_#{System.unique_integer([:positive])}")
    seed_dir = Path.join(test_dir, "seed")
    write_bundle!(Path.join(seed_dir, "components"))
    File.cp_r!(Path.join(@repo_root, "seed/aqua"), Path.join(seed_dir, "aqua"))

    stall = start_supervised!({Agent, fn -> nil end})

    {:ok, server} =
      Bandit.start_link(
        plug: {OCIRegistry, %{fixtures: fixtures(), stall: stall, observer: self()}},
        ip: {127, 0, 0, 1},
        port: 0
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    keys = [
      arca: :base_path,
      arca: :seed_path,
      cyfr: :oci_registry_url,
      cyfr: :registry_url,
      cyfr: :sigstore,
      cyfr: :provisioning_required_pull_budget_ms
    ]

    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)

    Application.put_env(:arca, :base_path, test_dir)
    Application.put_env(:arca, :seed_path, seed_dir)
    # `localhost:` is the one host the OCI reference layer maps to http.
    Application.put_env(:cyfr, :oci_registry_url, "localhost:#{port}")
    Application.put_env(:cyfr, :registry_url, "127.0.0.1:19")
    # A cosign on PATH would try to verify; point it at nothing so it fails fast.
    Application.put_env(:cyfr, :sigstore, verification: :keyed, key_path: "/nonexistent")
    Application.put_env(:cyfr, :provisioning_required_pull_budget_ms, @budget_ms)

    on_exit(fn ->
      for {{app, key}, value} <- prev do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end

      File.rm_rf!(test_dir)
      Process.exit(server, :normal)
    end)

    n = System.unique_integer([:positive])

    ctx =
      Sanctum.Context.build(
        user_id: "github|https://github.com|deadline-#{n}",
        athanor_id: Sanctum.TestContext.athanor_id(),
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, group} = Athanors.create_group(ctx.user_id, "Deadline #{n}")
    {:ok, ctx: %{ctx | athanor_id: group.id}, group: group, stall: stall}
  end

  test "a stalled required pull ends within its budget, releases coordination, and the next attempt completes the closure",
       %{ctx: ctx, group: group, stall: stall} do
    Agent.update(stall, fn _ -> "someone/catalysts/below" end)
    Application.put_env(:cyfr, :provisioning_required_pull_budget_ms, @cut_budget_ms)

    started = System.monotonic_time(:millisecond)
    :ok = Provisioning.start_provisioning(ctx)
    elapsed = System.monotonic_time(:millisecond) - started

    # The suite fills inline, so the attempt ran here: bounded by the
    # budget plus the seed scan and one answered pull, never by the
    # transport's own minutes-long patience.
    assert elapsed < 10 * @cut_budget_ms

    {:ok, group} = Athanors.get(group.id)
    refute group.provisioned_at

    assert %{step: "closure", detail: detail} = Athanors.provisioning_failure(group)

    assert detail =~ "timeout"

    # What landed before the cut stays; what was cut is not there.
    assert {:ok, _} = Compendium.Registry.get_latest(ctx, "elsewhere", "someone", "catalyst")

    assert {:error, :not_found} =
             Compendium.Registry.get_latest(ctx, "below", "someone", "catalyst")

    # The deadline settled the claim: failed, saying where and why, and no
    # longer standing — the retry below takes the estate at once.
    actor = %Cyfr.Actor{athanor_id: group.id}
    assert {:ok, %{outcome: "failed", outcome_detail: settled} = claim} = Claims.current(actor)
    assert settled =~ "closure"
    assert settled =~ "timeout"
    refute Claims.live?(claim)

    # The registry answers again: the explicit retry reads the installed
    # remote component's manifest, finds the dependency below it, and
    # finishes the closure.
    Agent.update(stall, fn _ -> nil end)
    assert {:ok, %{provisioned_at: %DateTime{}}} = Provisioning.provision(group, ctx)
    assert {:ok, _} = Compendium.Registry.get_latest(ctx, "below", "someone", "catalyst")
  end

  test "the seed sync heals a dependency an earlier attempt lost", %{ctx: ctx, group: group} do
    :ok = Provisioning.start_provisioning(ctx)
    {:ok, group} = Athanors.get(group.id)
    assert %DateTime{} = group.provisioned_at, inspect(Athanors.settings(group))

    # A transient outage at an earlier sync leaves one dependency of the
    # closure unpulled; dropping its row is exactly that state. The next
    # boot registers no new bundle versions, and the closure still heals.
    {:ok, below} = Compendium.Registry.get_latest(ctx, "below", "someone", "catalyst")

    :ok =
      Arca.ComponentStorage.delete_component(
        Sanctum.Context.actor(ctx),
        "below",
        below.version,
        "someone",
        nil
      )

    assert {:error, :not_found} =
             Compendium.Registry.get_latest(ctx, "below", "someone", "catalyst")

    assert :ok = Filler.sync_seeds()
    assert {:ok, _} = Compendium.Registry.get_latest(ctx, "below", "someone", "catalyst")
  end

  test "two members on one athanor's first touch: one fills it, the other pulls nothing and is told which case it is",
       %{ctx: ctx, group: group, stall: stall} do
    actor = %Cyfr.Actor{athanor_id: group.id}

    # The first member's attempt holds the estate's claim and is parked in
    # its required pull. It runs in a process of its own so the second
    # member's touch happens beside it, as two members' would.
    Agent.update(stall, fn _ -> "someone/catalysts/elsewhere" end)
    first = Task.async(fn -> Provisioning.provision(group, ctx) end)
    assert_receive {:stalled, "someone/catalysts/elsewhere"}, 10_000
    drain_manifests()

    # The second member's first touch of the same estate. It is told the
    # estate is being filled — not that it failed, and not silence — and
    # it asks the registry for nothing: one claim, one closure walk.
    assert {:error, :provisioning_busy} = Provisioning.provision(group, ctx)
    assert Provisioning.status(ctx) == :filling
    assert {:ok, %{fence: 1, outcome: nil}} = Claims.current(actor)
    refute_receive {:manifest, _repo}, 300

    # And the difference matters to the caller: busy is not the typed
    # failure a fill that ran and stopped would have answered.
    assert {:error, :not_provisioned} =
             Sanctum.MCP.AthanorTool.handle(ctx, %{"action" => "provision"})

    # The first member goes on and fills it, under the claim it never lost.
    Agent.update(stall, fn _ -> nil end)
    assert {:ok, %{provisioned_at: %DateTime{}}} = Task.await(first, 60_000)
    assert {:ok, %{fence: 1, outcome: "ready"}} = Claims.current(actor)
    assert {:ok, _} = Compendium.Registry.get_latest(ctx, "below", "someone", "catalyst")
  end

  test "an explicit retry that meets a running attempt is told it is in progress, at once",
       %{ctx: ctx, group: group} do
    # Another caller's attempt holds the claim — a background fill in
    # flight. The explicit verb does not queue behind it.
    actor = %Cyfr.Actor{athanor_id: group.id}
    {:ok, _held} = Claims.claim(actor, "boot_elsewhere/own_held", "first_need", 60_000)

    started = System.monotonic_time(:millisecond)
    assert {:error, :provisioning_busy} = Provisioning.provision(group, ctx)
    assert System.monotonic_time(:millisecond) - started < 1_000

    # The verb renders it as the same typed answer a turn gives while the
    # estate is being prepared — in progress, not a failure.
    assert {:error, :not_provisioned} =
             Sanctum.MCP.AthanorTool.handle(ctx, %{"action" => "provision"})
  end

  describe "a background fill in flight" do
    # The fill is a task here, as it is in a deployment, and its required
    # pull stalls on the registry until the attempt's deadline — long enough
    # to race it.
    setup %{stall: stall} do
      Application.put_env(:sanctum, :provisioning_inline, false)
      Application.put_env(:cyfr, :provisioning_required_pull_budget_ms, 3_000)
      on_exit(fn -> Application.put_env(:sanctum, :provisioning_inline, true) end)

      # A fill or a pull still running when the paths are restored would
      # work against the repository's own trees.
      Cyfr.Test.Sandbox.stop_work_on_exit()

      Agent.update(stall, fn _ -> "someone/catalysts/elsewhere" end)
      :ok
    end

    test "an explicit retry and an install are told busy at once; the deadline settles it failed, and readers back off",
         %{ctx: ctx, group: group} do
      actor = %Cyfr.Actor{athanor_id: group.id}

      # The reader answers at once and the fill goes on without it.
      started = System.monotonic_time(:millisecond)
      assert {:error, :not_provisioned} = Provisioning.ready(ctx)
      assert System.monotonic_time(:millisecond) - started < 1_000

      wait_until(fn -> Provisioning.status(ctx) == :filling end, 5_000, "the fill to claim")
      assert {:ok, %{entry_kind: "first_need", fence: 1, outcome: nil}} = Claims.current(actor)

      # Racing it: the explicit retry, the verb over it, and an install —
      # each refused without waiting, none of them touching the claim.
      started = System.monotonic_time(:millisecond)
      assert {:error, :provisioning_busy} = Provisioning.provision(group, ctx)

      assert {:error, :not_provisioned} =
               Sanctum.MCP.AthanorTool.handle(ctx, %{"action" => "provision"})

      assert {:error, :provisioning_busy} =
               Filler.install_shipped(ctx, "catalyst:local.foo")

      assert System.monotonic_time(:millisecond) - started < 2_000

      # And more readers add nothing.
      for _ <- 1..5, do: assert({:error, :not_provisioned} = Provisioning.ready(ctx))
      assert {:ok, %{fence: 1, outcome: nil}} = Claims.current(actor)

      # The deadline expires: the attempt settles its claim failed, with
      # where and why, and records the same on the row.
      wait_until(
        fn -> match?({:ok, %{outcome: "failed"}}, Claims.current(actor)) end,
        15_000,
        "the deadline to settle the claim"
      )

      assert {:ok, %{fence: 1, outcome_detail: detail}} = Claims.current(actor)
      assert detail =~ "closure"
      assert detail =~ "timeout"

      wait_until(
        fn ->
          {:ok, row} = Athanors.get(group.id)
          Athanors.provisioning_failure(row) != nil
        end,
        5_000,
        "the failure to reach the row"
      )

      # The fill's task and its keeper end before this test, which owns their
      # database connection, does.
      wait_until(
        fn -> Task.Supervisor.children(Sanctum.ProvisioningSupervisor) == [] end,
        5_000,
        "the fill's task and its keeper to end"
      )

      # A reader sees the failure and starts nothing for a minute.
      assert Provisioning.status(ctx) == :failed
      for _ <- 1..3, do: assert({:error, :not_provisioned} = Provisioning.ready(ctx))
      assert {:ok, %{fence: 1, outcome: "failed"}} = Claims.current(actor)
    end

    test "an attempt killed where it stands is released by its keeper, once its pull has stopped",
         %{ctx: ctx, group: group} do
      actor = %Cyfr.Actor{athanor_id: group.id}
      before = MapSet.new(Task.Supervisor.children(Compendium.ProvisioningSupervisor))

      # An explicit attempt, so the process to kill is known: it stalls in
      # its required pull, holding the claim.
      attempt = spawn(fn -> Provisioning.provision(group, ctx) end)

      wait_until(fn -> Provisioning.status(ctx) == :filling end, 5_000, "the attempt to claim")
      assert {:ok, %{entry_kind: "provision", fence: 1} = held} = Claims.current(actor)

      # Killed once it is parked in the pull, not before: the claim is
      # visible while the attempt still has queries to run, and a process
      # killed inside one takes the shared sandbox connection with it.
      assert_receive {:stalled, "someone/catalysts/elsewhere"}, 5_000

      # The pull runs beside the attempt, not inside it — unlinked, so its
      # crash stays its own — which is exactly what could outlive the
      # attempt and go on writing into an estate a successor holds.
      wait_until(fn -> started_beside(before) != nil end, 5_000, "the pull to be running")
      pull = started_beside(before)

      # Killed: no `after` runs, so nothing in the attempt lets go.
      killed_at = System.monotonic_time(:millisecond)
      Process.exit(attempt, :kill)

      wait_until(
        fn -> match?({:ok, %{outcome: "released"}}, Claims.current(actor)) end,
        10_000,
        "the keeper to release the dead attempt's claim"
      )

      # The claim came back only once the pull had stopped: a successor
      # taking the estate now is not racing a predecessor still writing to
      # it. And it came back on the keeper's watch, far inside the minute
      # the lease would otherwise have taken.
      refute Process.alive?(pull)
      assert System.monotonic_time(:millisecond) - killed_at < 10_000

      # Nothing was marked or recorded for it, and nothing half-landed:
      # the estate is unfilled, not partly filled.
      {:ok, row} = Athanors.get(group.id)
      refute row.provisioned_at
      refute Athanors.provisioning_failure(row)
      assert Provisioning.status(ctx) == :unfilled

      assert {:ok, []} =
               Arca.ProfileStorage.list_for_source(
                 Cyfr.Actor.in_athanor(group.id),
                 "catalyst:local.foo"
               )

      # The estate is free: the next claim is a new attempt at the next
      # fence, and the dead one's writes would be stale.
      assert {:ok, %{fence: 2}} = Claims.claim(actor, "boot_elsewhere/next", "provision", 1_000)
      assert :stale = Claims.settle(actor, held.owner, held.fence, "ready", nil)
    end

    # The one process the attempt started beside itself, measured as a
    # delta: the supervisor is shared, and an absolute reading would be
    # about whatever else the suite left running.
    defp started_beside(before) do
      Compendium.ProvisioningSupervisor
      |> Task.Supervisor.children()
      |> Enum.reject(&MapSet.member?(before, &1))
      |> case do
        [pid] -> pid
        _none_or_several -> nil
      end
    end
  end

  # Manifest requests the case has already accounted for. A `refute` about
  # who pulled next must not read a pull that has already been asserted.
  defp drain_manifests do
    receive do
      {:manifest, _repo} -> drain_manifests()
    after
      0 -> :ok
    end
  end

  # ---- fixtures ---------------------------------------------------------------

  # The bundle: one local catalyst that requires `catalyst:someone.elsewhere`.
  defp write_bundle!(bundle_dir) do
    src = Path.join([bundle_dir, "catalysts", "local", "foo", "1.0.0"])
    File.mkdir_p!(src)
    File.write!(Path.join(src, "catalyst.wasm"), @wasm)

    manifest = %{
      "name" => "foo",
      "version" => "1.0.0",
      "type" => "catalyst",
      "caps" => %{"egress" => %{"domains" => []}},
      "dependencies" => %{
        "static" => [%{"ref" => "catalyst:someone.elsewhere", "optional" => false}]
      }
    }

    File.write!(Path.join(src, "cyfr-manifest.json"), Jason.encode!(manifest))
  end

  # `elsewhere` requires `below`; `below` requires nothing.
  defp fixtures do
    Map.new(["elsewhere", "below"], fn name ->
      static =
        if name == "elsewhere",
          do: [%{"ref" => "catalyst:someone.below", "optional" => false}],
          else: []

      config =
        Jason.encode!(%{
          "name" => name,
          "version" => "1.0.0",
          "type" => "catalyst",
          "publisher" => "someone",
          "description" => "#{name} (fixture)",
          "dependencies" => %{"static" => static},
          "caps" => %{"egress" => %{"domains" => []}}
        })

      {:ok, manifest_json, config_digest, wasm_digest} =
        Compendium.OCI.Manifest.build(config, @wasm, "catalyst")

      {"someone/catalysts/#{name}",
       %{
         manifest: manifest_json,
         manifest_digest: Compendium.OCI.Blob.compute_digest(manifest_json),
         blobs: %{config_digest => config, wasm_digest => @wasm}
       }}
    end)
  end
end
