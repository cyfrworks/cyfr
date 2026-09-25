# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ApplicationTest do
  use ExUnit.Case, async: true

  require Record

  # The supervisor's own state, read for its strategy and intensity:
  # neither `Supervisor.count_children/1` nor a child spec carries them.
  Record.defrecordp(
    :supervisor_state,
    :state,
    for(
      {field, _default} <- Record.extract(:state, from_lib: "stdlib/src/supervisor.erl"),
      do: {field, nil}
    )
  )

  # A wildcard CORS origin once authentication is configured must fail closed
  # at boot in a real release, not merely warn. cors_enforcement/3 is the pure
  # decision seam the boot guard uses (first arg: auth configured?).
  describe "cors_enforcement/3" do
    test "auth configured + wildcard + real release => raise" do
      assert {:raise, msg} = Cyfr.Application.cors_enforcement(true, ["*"], true)
      assert msg =~ "FATAL"
      assert msg =~ "authentication enabled"
      assert msg =~ "CYFR_CORS_ALLOWED_ORIGINS"

      assert {:raise, _} =
               Cyfr.Application.cors_enforcement(true, ["https://a.example", "*"], true)
    end

    test "auth configured + wildcard outside a release => warn (dev/test not blocked)" do
      assert {:warn, msg} = Cyfr.Application.cors_enforcement(true, ["*"], false)
      assert msg =~ "suppressed outside a release"
    end

    test "auth configured with an explicit allowlist => ok" do
      assert :ok = Cyfr.Application.cors_enforcement(true, ["https://app.example"], true)
      assert :ok = Cyfr.Application.cors_enforcement(true, [], true)
    end

    test "no auth configured is never blocked, even with a wildcard in a release" do
      assert :ok = Cyfr.Application.cors_enforcement(false, ["*"], true)
      assert :ok = Cyfr.Application.cors_enforcement(false, ["*"], false)
    end
  end

  # The boot warns when CORS admits cross-origin callers the MCP Origin
  # check will then refuse. origin_allowlist_divergence/3 is the pure
  # decision seam it uses: the CORS allowlist, then the two MCP keys.
  describe "origin_allowlist_divergence/3" do
    test "an allowlist that admits an origin the MCP check would refuse warns" do
      assert {:warn, msg} =
               Cyfr.Application.origin_allowlist_divergence(["https://app.example"], nil, [])

      assert msg =~ "CYFR_MCP_ALLOWED_ORIGINS"
      assert msg =~ "https://app.example"
    end

    test "the empty allowlist admits nobody, so the shipped stack's boot says nothing" do
      # `cyfr init` assigns CYFR_CORS_ALLOWED_ORIGINS the empty allowlist:
      # cyfr serves Prism, the API, /mcp and the tinctures from its own
      # origin, so no browser client of the stack is cross-origin and there
      # is no request to warn about.
      assert :ok = Cyfr.Application.origin_allowlist_divergence([], nil, [])
    end

    test "the wildcard default is cors_enforcement/3's, not this one's" do
      assert :ok = Cyfr.Application.origin_allowlist_divergence(["*"], nil, [])
    end

    test "an MCP allowlist of either kind answers the divergence" do
      origins = ["https://app.example"]
      assert :ok = Cyfr.Application.origin_allowlist_divergence(origins, origins, [])
      assert :ok = Cyfr.Application.origin_allowlist_divergence(origins, nil, origins)
      assert :ok = Cyfr.Application.origin_allowlist_divergence(origins, [], [])
    end
  end

  describe "supervision tiers" do
    test "root supervises exactly the infra and web tier supervisors" do
      children = Supervisor.which_children(Cyfr.Supervisor)

      assert [{Cyfr.WebSupervisor, _, :supervisor, _}, {Cyfr.InfraSupervisor, _, :supervisor, _}] =
               children
    end

    test "data/infra children live under the infra tier" do
      ids =
        Cyfr.InfraSupervisor
        |> Supervisor.which_children()
        |> Enum.map(fn {id, _pid, _type, _mods} -> id end)

      assert Phoenix.PubSub.Supervisor in ids or
               Enum.any?(ids, fn id -> id == Cyfr.PubSub end)

      # The repo is the `arca` application's, and so is the cache table's
      # owner; this tier reaches the repo by name. The operation table is
      # a term written before the tree starts, owned by no child.
      refute Grimoire.Catalog in ids
      refute Emissary.MCP.ResourceRegistry in ids
      assert is_map(Grimoire.operations())
      refute Arca.Repo in ids
      refute CyfrWeb.Endpoint in ids
    end

    # The persistence layer's own tree: the pool, the write-behind that
    # drains through it, and the shared cache table's owner. Shutdown is
    # reverse start order, so "after the repo" is what makes the
    # bookkeeping sink stop BEFORE it: the rows `terminate/2` drains are
    # written through a pool that is still open. Started the other way
    # round, every row buffered at shutdown would be lost silently.
    test "the repo, its write-behind and the cache owner live under the arca tree" do
      started = Arca.Supervisor |> started_ids()
      at = fn id -> Enum.find_index(started, &(&1 == id)) end

      assert is_integer(at.(Arca.Repo))
      assert is_integer(at.(Arca.RecordSink))
      assert is_integer(at.(Arca.Cache.Sweeper))

      assert at.(Arca.RecordSink) > at.(Arca.Repo),
             "the record sink must start after Arca.Repo so it drains before the repo goes down"
    end

    # The auth domain's own tree: what outlives a request that charged a
    # budget, the sliver's HTTP pool, and the single-flight registry.
    test "the invoke-budget guard and the auth pool live under the sanctum tree" do
      started = Sanctum.Supervisor |> started_ids()

      assert Sanctum.Authority.BudgetGuard in started
      assert Sanctum.OAuth.RefreshTree in started
      assert Sanctum.ProvisioningSupervisor in started
      assert is_pid(Process.whereis(Sanctum.Auth.Finch))
    end

    # Each domain's processes are one subtree of the infra tier, started
    # after PubSub in the order the domains call one another; the schedule
    # pair follows them, so a fire never reaches a tree that is not up,
    # and the console's children come last.
    test "the domains' subtrees start under the infra tier after PubSub, in order" do
      started = Cyfr.InfraSupervisor |> started_ids()
      pubsub = Enum.find_index(started, &(&1 in [Cyfr.PubSub, Phoenix.PubSub.Supervisor]))

      order = [
        Grimoire.Supervisor,
        Compendium.Supervisor,
        Crucible.Supervisor,
        Aqua.Supervisor,
        Emissary.Supervisor,
        Crucible.Schedules.TaskSupervisor,
        Crucible.Schedules.Scheduler,
        Prism.TinctureRegistry,
        Prism.TaskSupervisor
      ]

      assert Enum.filter(started, &(&1 in order)) == order
      assert Enum.find_index(started, &(&1 == Grimoire.Supervisor)) > pubsub

      for {supervisor, children} <- [
            {Grimoire.Supervisor, [Grimoire.RunningTasks, Grimoire.TaskSupervisor]},
            {Compendium.Supervisor,
             [
               Compendium.Builds.TaskSupervisor,
               Compendium.ProvisioningSupervisor,
               Compendium.Provisioning,
               Compendium.ProjectionReconciler
             ]},
            {Crucible.Supervisor,
             [
               Crucible.Slots,
               Crucible.Tree,
               Crucible.TaskSupervisor,
               Crucible.ArchiveWatch,
               Crucible.Sweeper,
               Crucible.WorkerWatch,
               Crucible.HostListener
             ]},
            {Aqua.Supervisor, [Aqua.ScheduleNotes, Aqua.WorkerTree, Aqua.RunnerTree]},
            {Emissary.Supervisor, [Emissary.External.ServerTree, Emissary.TaskSupervisor]}
          ] do
        assert started_ids(supervisor) == children,
               "#{inspect(supervisor)} must hold #{inspect(children)} in start order"

        for child <- children, do: refute(child in started)
      end
    end

    test "execution slots, event streams and attempts start first in the execution subtree" do
      started = Crucible.Supervisor |> started_ids()

      # The consented rate is not among them: its window is a shared row,
      # so this boot starts nothing for it.
      refute Crucible.Rates in started
      assert [Crucible.Slots, Crucible.Tree | _] = started

      assert [
               Crucible.Registry,
               Crucible.Events.Registry,
               Crucible.Events.Sequence,
               Crucible.Events.Supervisor,
               Crucible.Attempt.Registry,
               Crucible.Attempt.Supervisor
             ] = started_ids(Crucible.Tree)
    end

    test "background roots and the stale-execution sweeper start after the execution group" do
      started = Crucible.Supervisor |> started_ids()
      at = fn id -> Enum.find_index(started, &(&1 == id)) end

      # The sweeper is a child even where `:execution_sweeper_enabled` is off
      # and it did not start.
      for id <- [Crucible.TaskSupervisor, Crucible.Sweeper] do
        assert is_integer(at.(id)) and at.(id) > at.(Crucible.Tree),
               "#{inspect(id)} must start under the execution subtree after Crucible.Tree"
      end
    end

    # Builds run on the control plane's own task supervisor and nowhere
    # else: this server starts no builder, and a build's request, watcher and
    # registration stop before the bookkeeping they write through.
    test "the builds' task supervisor starts under the component subtree, and no builder does" do
      started = Compendium.Supervisor |> started_ids()

      assert Compendium.Builds.TaskSupervisor in started
      assert is_pid(Process.whereis(Compendium.Builds.TaskSupervisor))

      for supervisor <- [Cyfr.InfraSupervisor, Compendium.Supervisor] do
        refute supervisor |> started_ids() |> Enum.any?(&(inspect(&1) =~ "Locus"))
      end
    end

    test "the host API listener starts under the execution subtree after the attempts it serves" do
      started = Crucible.Supervisor |> started_ids()
      at = fn id -> Enum.find_index(started, &(&1 == id)) end

      # Shutdown is reverse start order: the listener stops taking host
      # calls before the attempt tree and the roots that wait on them go.
      assert is_integer(at.(Crucible.HostListener))
      assert at.(Crucible.HostListener) > at.(Crucible.Tree)
      assert at.(Crucible.HostListener) > at.(Crucible.TaskSupervisor)

      # Bound where the configuration says, on the port the suite asked for
      # (0: one of the system's choosing), and answering as the host API.
      {_, listener, :supervisor, _} =
        Crucible.Supervisor
        |> Supervisor.which_children()
        |> List.keyfind(Crucible.HostListener, 0)

      assert Cyfr.RuntimeConfig.host_api_port() == 0
      port = Crucible.HostListener.port(listener)
      assert port > 0
      assert Cyfr.Test.OpusService.host_url() == "http://127.0.0.1:#{port}"

      {:ok, %Req.Response{status: 401, body: body}} =
        Req.post("http://127.0.0.1:#{port}" <> Prima.WorkerWire.host_route(:attach),
          body: "{}",
          retry: false,
          decode_body: false
        )

      assert Jason.decode!(body) == %{"error" => "lost"}
    end

    # The census the admission barrier test pins is the tree that runs:
    # every supervisor it describes is running under that id, with that
    # strategy and intensity, over exactly those children in that order.
    test "the census names exactly the running tree" do
      tiers = Cyfr.Application.tiers()
      assert started_ids(Cyfr.Supervisor) == Enum.map(tiers, &elem(&1, 0))

      for {id, _, _, _} = tier <- tiers do
        {^id, pid, :supervisor, _} =
          Cyfr.Supervisor |> Supervisor.which_children() |> List.keyfind(id, 0)

        assert_runs(tier, pid)
      end
    end

    test "the endpoint lives under the web tier" do
      ids =
        Cyfr.WebSupervisor
        |> Supervisor.which_children()
        |> Enum.map(fn {id, _pid, _type, _mods} -> id end)

      assert CyfrWeb.Endpoint in ids
      refute Arca.Repo in ids
    end
  end

  defp assert_runs({id, strategy, intensity, children}, pid) do
    state = :sys.get_state(pid)

    assert {supervisor_state(state, :strategy),
            {supervisor_state(state, :intensity), supervisor_state(state, :period)}} ==
             {strategy, intensity},
           "#{inspect(id)} runs with another strategy or intensity than the census says"

    assert started_ids(pid) == Enum.map(children, &census_id/1),
           "#{inspect(id)} runs other children than the census says"

    running = Supervisor.which_children(pid)

    for {child_id, _, _, _} = nested <- children do
      {^child_id, child, :supervisor, _} = List.keyfind(running, child_id, 0)
      assert_runs(nested, child)
    end
  end

  defp census_id({id, _strategy, _intensity, _children}), do: id
  defp census_id(child), do: Supervisor.child_spec(child, []).id

  defp started_ids(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.map(fn {id, _pid, _type, _mods} -> id end)
    |> Enum.reverse()
  end

  describe "parse_keyring_env!/1" do
    defp keyring_json(keys, primary) do
      Jason.encode!(%{
        "primary" => primary,
        "keys" => Map.new(keys, fn {label, bytes} -> {label, Base.encode64(bytes)} end)
      })
    end

    defp material(seed), do: :crypto.hash(:sha256, seed)

    test "accepts a well-formed keyring" do
      json = keyring_json(%{"k1" => material("a"), "k2" => material("b")}, "k2")

      assert %{primary: "k2", keys: keys} = Cyfr.Application.parse_keyring_env!(json)
      assert map_size(keys) == 2
    end

    test "refuses the same material under two labels — a rotation that is not one" do
      # The derived key is a function of the material and the purpose, never
      # the label, so these two labels are one key with two names.
      # Re-encrypting onto "new" would leave every row under the key it
      # already had while the rotation audit reported success.
      shared = material("same")
      json = keyring_json(%{"old" => shared, "new" => shared}, "new")

      assert_raise RuntimeError, ~r/reuses the same key material/, fn ->
        Cyfr.Application.parse_keyring_env!(json)
      end
    end

    test "refuses a label the envelope's one length byte cannot describe" do
      json = keyring_json(%{String.duplicate("x", 256) => material("a")}, "k")

      assert_raise RuntimeError, ~r/labels must be 1\.\.255 bytes/, fn ->
        Cyfr.Application.parse_keyring_env!(json)
      end
    end

    test "refuses an empty label — it decrypts but reads as unknown to the rotation audit" do
      # `primary` being empty is caught by the outer shape guard; this is the
      # case that got past it — a valid primary alongside an empty-labelled
      # key, which `Sanctum.Cipher.envelope/1` (llen > 0) cannot classify.
      json = keyring_json(%{"k" => material("a"), "" => material("b")}, "k")

      assert_raise RuntimeError, ~r/empty key label/, fn ->
        Cyfr.Application.parse_keyring_env!(json)
      end
    end

    test "still refuses short material and a primary that names no key" do
      short = Jason.encode!(%{"primary" => "k", "keys" => %{"k" => Base.encode64("tooshort")}})

      assert_raise RuntimeError, ~r/not >= 32 bytes/, fn ->
        Cyfr.Application.parse_keyring_env!(short)
      end

      orphan = keyring_json(%{"k" => material("a")}, "absent")

      assert_raise RuntimeError, ~r/is not in :keys/, fn ->
        Cyfr.Application.parse_keyring_env!(orphan)
      end
    end
  end
end
