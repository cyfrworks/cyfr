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

  # Every long-running child's stated stop bound: a GenServer's stop, a
  # task supervisor's longest task, the scheduler's timers. A supervisor
  # waits for its own children and keeps `:infinity`.
  @shutdowns %{
    Cyfr.Cell => 5_000,
    Arca.AuditHandler => 5_000,
    Cyfr.StandingWatch => 5_000,
    Cyfr.TelemetryBridge => 5_000,
    Cyfr.Platform.Settings => 5_000,
    Cyfr.RetentionScheduler => 5_000,
    Sanctum.RunningTasks => 5_000,
    Sanctum.Gate.TaskSupervisor => 30_000,
    Compendium.Builds.TaskSupervisor => 30_000,
    Compendium.ProvisioningSupervisor => 30_000,
    Compendium.ProjectionReconciler => 5_000,
    Opus.Slots => 5_000,
    Opus.Events.Sequence => 5_000,
    Opus.TaskSupervisor => 30_000,
    Opus.ArchiveWatch => 5_000,
    Opus.Sweeper => 5_000,
    Opus.WorkerWatch => 5_000,
    Opus.Host.Egress.Pins => 5_000,
    Aqua.ScheduleNotes => 5_000,
    Aqua.Loop.Worker => 5_000,
    Aqua.TaskSupervisor => 30_000,
    Emissary.External.Backends => 5_000,
    Emissary.External.Reconciler => 5_000,
    Emissary.TaskSupervisor => 30_000,
    Opus.Schedules.TaskSupervisor => 30_000,
    Opus.Schedules.Scheduler => 10_000,
    Prism.TinctureRegistry => 5_000,
    Prism.TaskSupervisor => 30_000,
    Emissary.Web.TaskSupervisor => 30_000,
    Cyfr.SeedOffer => 5_000
  }

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

  # The endpoint's listeners as its adapter starts them (`CyfrWeb.Ingress`),
  # under a supervisor with the endpoint's child id, as the tree holds it:
  # the proxy listener exists when `config/runtime.exs` writes the access
  # settings' `proxy:` (a tailnet or public home), and `extra` beside them.
  defp endpoint_tree(proxy?, extra \\ []) do
    address = [ip: {127, 0, 0, 1}, port: 0]
    proxy = if proxy?, do: [proxy: address], else: []

    servers =
      CyfrWeb.Ingress.child_specs(
        CyfrWeb.Endpoint,
        [otp_app: :cyfr, http: address ++ [startup_log: false]] ++ proxy
      )

    endpoint = %{
      id: CyfrWeb.Endpoint,
      start: {Supervisor, :start_link, [servers ++ extra, [strategy: :one_for_one]]},
      type: :supervisor
    }

    root =
      start_supervised!(%{
        id: {__MODULE__, proxy?},
        start: {Supervisor, :start_link, [[endpoint], [strategy: :one_for_one]]},
        type: :supervisor
      })

    [{CyfrWeb.Endpoint, endpoint, :supervisor, _}] = Supervisor.which_children(root)
    {root, endpoint}
  end

  describe "the endpoint's listeners" do
    test "the census holds the proxy listener in a tailnet or public home, and none in a local one" do
      {local, _endpoint} = endpoint_tree(false)
      assert Cyfr.Application.listeners(local) == [CyfrWeb.Endpoint]
      assert Cyfr.Application.check_listeners!(Cyfr.Application.listeners(local)) == :ok

      {exposed, _endpoint} = endpoint_tree(true)
      listeners = Cyfr.Application.listeners(exposed)

      assert Enum.sort(listeners) == Enum.sort([CyfrWeb.Endpoint, CyfrWeb.Ingress.Proxy])
      assert Cyfr.Application.check_listeners!(listeners) == :ok
    end

    test "a listener beside them the roster does not name refuses the boot, naming it alone" do
      rogue = %{
        id: Planted.RogueListener,
        start:
          {Supervisor, :start_link,
           [
             [{Bandit, plug: Plug.Head, ip: {127, 0, 0, 1}, port: 0, startup_log: false}],
             [strategy: :one_for_one]
           ]},
        type: :supervisor
      }

      {root, _endpoint} = endpoint_tree(true, [rogue])

      error =
        assert_raise RuntimeError, fn ->
          root |> Cyfr.Application.listeners() |> Cyfr.Application.check_listeners!()
        end

      assert error.message =~ "Planted.RogueListener"
      refute error.message =~ "CyfrWeb.Ingress.Proxy"
      refute error.message =~ "  - CyfrWeb.Endpoint"
    end

    test "the graceful stop finds both listeners' servers, and the loopback listener's alone in a local home" do
      {_root, local} = endpoint_tree(false)
      assert [_loopback] = Cyfr.Application.endpoint_servers(local)

      {_root, exposed} = endpoint_tree(true)
      servers = Cyfr.Application.endpoint_servers(exposed)
      assert length(servers) == 2

      ports =
        for server <- servers do
          {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
          port
        end

      assert Enum.uniq(ports) == ports
    end
  end

  describe "supervision tiers" do
    test "root supervises exactly the infra and web tier supervisors" do
      children = Supervisor.which_children(Cyfr.Supervisor)

      assert [{Cyfr.WebSupervisor, _, :supervisor, _}, {Cyfr.InfraSupervisor, _, :supervisor, _}] =
               children
    end

    # A child of the infra tier restarts everything after it, the gate
    # among them; the web tier restarts a child alone, so an endpoint in a
    # crash loop exhausts only its own budget; the root restarts a failed
    # tier and every tier after it.
    test "the root and the infra tier restart the rest, the web tier each child alone" do
      for {supervisor, strategy} <- [
            {Cyfr.Supervisor, :rest_for_one},
            {Cyfr.InfraSupervisor, :rest_for_one},
            {Cyfr.WebSupervisor, :one_for_one}
          ] do
        state = :sys.get_state(supervisor)

        assert {supervisor_state(state, :strategy), supervisor_state(state, :intensity),
                supervisor_state(state, :period)} == {strategy, 10, 60},
               "#{inspect(supervisor)} runs with another strategy or intensity"
      end
    end

    test "data/infra children live under the infra tier" do
      ids =
        Cyfr.InfraSupervisor
        |> Supervisor.which_children()
        |> Enum.map(fn {id, _pid, _type, _mods} -> id end)

      assert Phoenix.PubSub.Supervisor in ids

      # The repo is the `arca` application's, and so is the cache table's
      # owner; this tier reaches the repo by name. The operation table is
      # a term written before the tree starts, owned by no child.
      assert is_map(Sanctum.Catalog.operations())
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
      pubsub = Enum.find_index(started, &(&1 == Phoenix.PubSub.Supervisor))

      order = [
        Sanctum.Gate.Supervisor,
        Compendium.Supervisor,
        Opus.Supervisor,
        Aqua.Supervisor,
        Emissary.Supervisor,
        Opus.Schedules.TaskSupervisor,
        Opus.Schedules.Scheduler,
        Prism.TinctureRegistry,
        Prism.TaskSupervisor
      ]

      assert Enum.filter(started, &(&1 in order)) == order
      assert Enum.find_index(started, &(&1 == Sanctum.Gate.Supervisor)) > pubsub

      for {supervisor, children} <- [
            {Sanctum.Gate.Supervisor, [Sanctum.RunningTasks, Sanctum.Gate.TaskSupervisor]},
            {Compendium.Supervisor,
             [
               Compendium.Builds.TaskSupervisor,
               Compendium.ProvisioningSupervisor,
               Compendium.ProjectionReconciler
             ]},
            {Opus.Supervisor,
             [
               Opus.Slots,
               Opus.Tree,
               Opus.TaskSupervisor,
               Opus.ArchiveWatch,
               Opus.Sweeper,
               Opus.WorkerWatch,
               Opus.Host.Egress.Pins,
               Opus.HostListener
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
      started = Opus.Supervisor |> started_ids()

      assert [Opus.Slots, Opus.Tree | _] = started

      assert [
               Opus.Registry,
               Opus.Events.Registry,
               Opus.Events.Sequence,
               Opus.Events.Supervisor,
               Opus.Attempt.Registry,
               Opus.Attempt.Supervisor
             ] = started_ids(Opus.Tree)
    end

    test "background roots and the stale-execution sweeper start after the execution group" do
      started = Opus.Supervisor |> started_ids()
      at = fn id -> Enum.find_index(started, &(&1 == id)) end

      # The sweeper is a child even where `:execution_sweeper_enabled` is off
      # and it did not start.
      for id <- [Opus.TaskSupervisor, Opus.Sweeper] do
        assert is_integer(at.(id)) and at.(id) > at.(Opus.Tree),
               "#{inspect(id)} must start under the execution subtree after Opus.Tree"
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
      started = Opus.Supervisor |> started_ids()
      at = fn id -> Enum.find_index(started, &(&1 == id)) end

      # Shutdown is reverse start order: the listener stops taking host
      # calls before the attempt tree and the roots that wait on them go.
      assert is_integer(at.(Opus.HostListener))
      assert at.(Opus.HostListener) > at.(Opus.Tree)
      assert at.(Opus.HostListener) > at.(Opus.TaskSupervisor)

      # Bound where the configuration says, on the port the suite asked for
      # (0: one of the system's choosing), and answering as the host API.
      {_, listener, :supervisor, _} =
        Opus.Supervisor
        |> Supervisor.which_children()
        |> List.keyfind(Opus.HostListener, 0)

      assert Cyfr.RuntimeConfig.host_api_port() == 0
      port = Opus.HostListener.port(listener)
      assert port > 0
      assert Cyfr.Test.RuntimeService.host_url() == "http://127.0.0.1:#{port}"

      {:ok, %Req.Response{status: 401, body: body}} =
        Req.post("http://127.0.0.1:#{port}" <> Prima.WorkerWire.host_route(:attach),
          body: "{}",
          retry: false,
          decode_body: false
        )

      assert Jason.decode!(body) == %{"v" => 1, "error" => "lost"}
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

    # Each child is stopped within its stated bound, read from the child
    # spec its running supervisor holds. The suite's boot omits the cell
    # (`:control_plane_claim_enabled`); the admission barrier test reads
    # its bound from the census.
    test "every long-running child in the census stops within its stated bound" do
      children =
        for {id, _, _, _} = tier <- Cyfr.Application.tiers(),
            {^id, pid, :supervisor, _} =
              List.keyfind(Supervisor.which_children(Cyfr.Supervisor), id, 0),
            child <- running_specs(tier, pid),
            do: child

      for %{id: id, shutdown: shutdown, type: type, written?: written?} <- children do
        case Map.fetch(@shutdowns, id) do
          {:ok, bound} ->
            assert {shutdown, written?} == {bound, true},
                   "#{inspect(id)} does not state its bound where it is declared"

          :error ->
            assert {type, shutdown} == {:supervisor, :infinity},
                   "#{inspect(id)} is long-running and states no bound"
        end
      end

      assert Enum.sort(Map.keys(@shutdowns) -- Enum.map(children, & &1.id)) ==
               [Cyfr.Cell, Cyfr.SeedOffer]
    end

    # The seed offer is boot work, which the suite's boot omits, so the
    # census reads the spec the boot would start: its bound is stated in
    # the server's own declaration, not left to the default.
    test "the seed offer states its stop bound where it is declared" do
      spec = Cyfr.Application.seed_offer_spec()

      assert %{id: Cyfr.SeedOffer, restart: :temporary, shutdown: bound} = spec
      assert bound == Map.fetch!(@shutdowns, Cyfr.SeedOffer)
      assert Map.has_key?(Cyfr.SeedOffer.child_spec([]), :shutdown)
    end

    # A tier returns from its stop only once each child is down, a worker
    # within its bound. The claim holders are workers under the infra
    # tier, so none outlives it; and `:cyfr` stops before `:arca`, which
    # it depends on, so the pool they release through is still open. The
    # cell and the gate, which the suite's boot omits, are the admission
    # barrier test's.
    test "the claim holders stop inside the infra tier, before the pool closes" do
      assert :arca in Application.spec(:cyfr, :applications)

      for {path, id} <- [
            {[], Cyfr.RetentionScheduler},
            {[Opus.Supervisor], Opus.WorkerWatch},
            {[Emissary.Supervisor, Emissary.External.ServerTree], Emissary.External.Backends}
          ] do
        supervisor = child_pid(Cyfr.InfraSupervisor, path)

        assert {:ok, %{type: :worker, shutdown: bound}} =
                 :supervisor.get_childspec(supervisor, id)

        assert is_integer(bound)
      end
    end

    # The endpoint's drain is one setting in `config/config.exs`, merged
    # under every environment's `http:`, and the release's runtime
    # configuration does not set it again.
    test "the endpoint drains its connections for 30 s in every environment" do
      drain = [:thousand_island_options, :shutdown_timeout]
      assert get_in(CyfrWeb.Endpoint.config(:http), drain) == 30_000

      root = Path.expand("../../../..", __DIR__)

      for env <- [:dev, :test, :prod] do
        config = Config.Reader.read!(Path.join(root, "config/config.exs"), env: env)

        assert get_in(config, [:cyfr, CyfrWeb.Endpoint, :http | drain]) == 30_000,
               "the #{env} endpoint drains for another time"
      end

      refute File.read!(Path.join(root, "config/runtime.exs")) =~ "shutdown_timeout"
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

  # The child spec each running supervisor holds for every leaf of the
  # census below it, and whether the census states its shutdown rather
  # than leaving the module's default.
  defp running_specs({_id, _, _, children}, pid) do
    running = Supervisor.which_children(pid)

    Enum.flat_map(children, fn
      {child_id, _, _, _} = nested ->
        {^child_id, child, :supervisor, _} = List.keyfind(running, child_id, 0)
        running_specs(nested, child)

      child ->
        {:ok, spec} = :supervisor.get_childspec(pid, census_id(child))
        [Map.put(spec, :written?, Map.has_key?(Supervisor.child_spec(child, []), :shutdown))]
    end)
  end

  defp child_pid(supervisor, []), do: supervisor

  defp child_pid(supervisor, [id | path]) do
    {^id, pid, :supervisor, _} = supervisor |> Supervisor.which_children() |> List.keyfind(id, 0)
    child_pid(pid, path)
  end

  defp census_id({id, _strategy, _intensity, _children}), do: id
  defp census_id(child), do: Supervisor.child_spec(child, []).id

  defp started_ids(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.map(fn {id, _pid, _type, _mods} -> id end)
    |> Enum.reverse()
  end

  describe "derive_keyring!/1" do
    # The configured key base is held to the rule runtime.exs holds
    # CYFR_SECRET_KEY_BASE to, with the same sentence, so an operator who
    # follows this refusal is not refused again at the next boot.
    defp keyring_refusal(key_base) do
      Exception.message(
        assert_raise(RuntimeError, fn -> Cyfr.Application.derive_keyring!(key_base) end)
      )
    end

    test "refuses a missing key base as runtime.exs does" do
      assert {:error, rule} = Cyfr.RuntimeConfig.check_secret_key_base(nil)
      assert rule =~ "CYFR_SECRET_KEY_BASE is missing"
      assert keyring_refusal(nil) =~ "cannot derive :crypto_keyring: " <> rule
    end

    for {label, key_base, reason} <- [
          {"blank", "   ", "is blank"},
          {"63 bytes", "short-key-base-" <> String.duplicate("q", 47) <> "!",
           "is shorter than 64 bytes"}
        ] do
      test "refuses a #{label} key base as runtime.exs does, without the value" do
        key_base = unquote(key_base)
        assert {:error, rule} = Cyfr.RuntimeConfig.check_secret_key_base(key_base)
        assert rule =~ "CYFR_SECRET_KEY_BASE #{unquote(reason)}"

        message = keyring_refusal(key_base)
        assert message =~ "cannot derive :crypto_keyring: " <> rule
        refute String.contains?(message, key_base)
      end
    end

    test "derives the one default key from a key base of 64 bytes" do
      key_base = String.duplicate("k", 63) <> "!"
      master = :crypto.hash(:sha256, "cyfr-cipher-keyring|" <> key_base)

      assert Cyfr.Application.derive_keyring!(key_base) ==
               %{primary: "default", keys: %{"default" => master}}
    end
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
      # An empty `primary` is the outer shape guard's; this is a valid
      # primary alongside an empty-labelled key, which
      # `Sanctum.Cipher.envelope/1` (llen > 0) cannot classify.
      json = keyring_json(%{"k" => material("a"), "" => material("b")}, "k")

      assert_raise RuntimeError, ~r/empty key label/, fn ->
        Cyfr.Application.parse_keyring_env!(json)
      end
    end

    test "refuses short material and a primary that names no key" do
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
