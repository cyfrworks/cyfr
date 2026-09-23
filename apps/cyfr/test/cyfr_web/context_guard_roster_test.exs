# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.ContextGuardRosterTest do
  @moduledoc """
  Every console callback that holds a session context passes
  `CyfrWeb.ContextGuard`, and the roster of those callbacks is exact.

  The roster is the session-bearing callback inventory taken when the
  guard was introduced: the routed LiveViews, the nested ones, the
  LiveComponents and the tasks whose results come back to a socket. The
  tree is read against it both ways — a LiveView, component or task the
  roster does not name fails here until it is guarded and named, and a
  roster row whose module is gone fails too.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @prism_web "apps/cyfr/lib/prism_web"

  # Routed through the `:athanor` live_session, whose on_mount is the guard.
  @routed ~w(
    RootRedirectLive ChatRedirectLive ChatLive AquaLive FilesLive ActivitiesLive
    EnforcementsLive ExecutionsLive ComponentsLive ComponentDetailLive RegistryLive
    MyReportsLive BuildsLive VaultLive ApiKeysLive MembersLive WebhooksLive
    SchedulesLive SettingsLive McpServersLive ShellLive LegalLive
  )

  # The sign-in page is what an anonymous caller comes for; it holds no context.
  @public ~w(LoginLive)

  # Rendered by the layout or a page with `live_render/3`; each mounts the guard itself.
  @nested ~w(TopbarLive AquaPanelLive ThreadPaneLive)

  # Each `handle_event` and `update` that acts on the context runs inside `guard/2`.
  @components ~w(
    AquaLive.AgentsComponent AquaLive.NotesComponent AquaLive.RestoreComponent
    AquaLive.ScrollsComponent ConsentSheetComponent ReportComponent
    CommandPaletteLiveComponent AquaApprovalCard
  )

  # The tasks started from the console, by file, and the files that take
  # their answers through `deliver/3`. Every other deferred path — pane and
  # host messages, runner broadcasts, a component's message to its page,
  # `send_update/3` fan-out — lands in a guarded callback of its own.
  @tasks %{
    "model_catalog.ex" => {1, ["live/aqua_live.ex", "live/thread_pane_live.ex"]},
    "live/components_live.ex" => {4, ["live/components_live.ex"]},
    "live/builds_live.ex" => {1, ["live/builds_live.ex"]},
    "live/shell_live.ex" => {1, ["live/shell_live.ex"]},
    "live/aqua_live/agents_component.ex" => {1, ["live/aqua_live.ex"]}
  }

  @capture ~r/\bCyfrWeb\.ContextGuard\.capture\(/

  @task_start ~r/\b(Task\.Supervisor\.(start_child|async|async_nolink)|Task\.(async|start|start_link)|start_async|assign_async)\(/

  # What a callback body names when it acts on the context: the context
  # itself, or the adapters that read it off the socket.
  @context_markers [:context, :call_tool, :call_aqua, :fetch_list, :ctx]

  defp sources do
    Path.wildcard(Path.join([@root, @prism_web, "**", "*.ex"]))
    |> Map.new(&{Path.relative_to(&1, Path.join(@root, @prism_web)), File.read!(&1)})
  end

  defp modules_using(sources, kinds) do
    for {path, text} <- sources,
        Regex.match?(~r/use (PrismWeb, :(#{kinds})|Phoenix\.Live(View|Component)\b)/, text),
        [_, name] <- [Regex.run(~r/defmodule PrismWeb\.([\w.]+) do/, text)],
        into: %{},
        do: {name, path}
  end

  defp mod(name), do: Module.concat(PrismWeb, name)

  test "every LiveView in the console is rostered as routed, nested or public, and nothing else" do
    found = sources() |> modules_using("live_view") |> Map.keys() |> MapSet.new()
    rostered = MapSet.new(@routed ++ @nested ++ @public)

    assert MapSet.difference(found, rostered) == MapSet.new(),
           "LiveViews the guard roster does not name — guard them and add them here"

    assert MapSet.difference(rostered, found) == MapSet.new(),
           "roster rows whose LiveView is gone — remove them"
  end

  test "every routed LiveView is mounted through the guard, and every live route is rostered" do
    live_routes =
      for %{metadata: %{phoenix_live_view: {view, _action, _opts, session}}} <-
            EmissaryWeb.Router.__routes__(),
          do: {view, session}

    routed_views = MapSet.new(live_routes, fn {view, _} -> view end)

    for name <- @routed do
      assert mod(name) in routed_views, "#{name} is rostered as routed and has no live route"
    end

    for {view, session} <- live_routes, view not in Enum.map(@public, &mod/1) do
      assert view in Enum.map(@routed, &mod/1), "#{inspect(view)} is routed and not rostered"

      on_mount = get_in(session, [:extra, :on_mount]) || []

      assert Enum.any?(on_mount, &match?(%{id: {CyfrWeb.ContextGuard, :protected}}, &1)),
             "#{inspect(view)} is routed without CyfrWeb.ContextGuard on mount"
    end
  end

  test "every nested LiveView mounts the guard itself" do
    for name <- @nested do
      hooks = mod(name).__live__().lifecycle.mount

      assert Enum.any?(hooks, &match?(%{id: {CyfrWeb.ContextGuard, :protected}}, &1)),
             "#{name} is nested without `on_mount {CyfrWeb.ContextGuard, :protected}`"
    end
  end

  test "every component is rostered, and each callback that acts on the context is guarded" do
    sources = sources()
    found = modules_using(sources, "live_component")

    assert found |> Map.keys() |> MapSet.new() == MapSet.new(@components),
           "the LiveComponents and the guard roster differ: #{inspect(Map.keys(found))}"

    unguarded =
      for {name, path} <- found,
          {callback, line} <- unguarded_callbacks(Map.fetch!(sources, path)),
          do: "#{name}.#{callback} (#{path}:#{line})"

    assert unguarded == [],
           "component callbacks act on the context outside `CyfrWeb.ContextGuard.guard/2`:\n" <>
             Enum.join(unguarded, "\n")
  end

  test "every task the console starts is rostered, captures its focus, and is delivered through the guard" do
    sources = sources()
    starts = counts(sources, @task_start)

    assert starts == Map.new(@tasks, fn {path, {n, _}} -> {path, n} end),
           "the console's task starts and the guard roster differ: #{inspect(starts)}"

    # One capture per task started, file by file: a second task in a file
    # that already captures once is not covered by the first.
    assert counts(sources, @capture) == starts,
           "the focus captures and the task starts differ, file by file"

    for {path, {_n, consumers}} <- @tasks, consumer <- consumers do
      assert Map.has_key?(sources, consumer),
             "#{path}'s answer is rostered to #{consumer}, which is gone"

      assert sources[consumer] =~ "CyfrWeb.ContextGuard.deliver(",
             "#{consumer} takes #{path}'s answer without CyfrWeb.ContextGuard.deliver/3"
    end
  end

  defp counts(sources, pattern) do
    for {path, text} <- sources,
        n = length(Regex.scan(pattern, text)),
        n > 0,
        into: %{},
        do: {path, n}
  end

  test "the catalog adapter holds every context to the guard before it dispatches" do
    assert Map.fetch!(sources(), "ops.ex") =~ "CyfrWeb.ContextGuard.check(ctx)"
  end

  test "the drift check fails a planted component callback that skips the guard" do
    planted = """
    defmodule PrismWeb.Planted do
      use PrismWeb, :live_component

      def handle_event("go", _params, socket) do
        {:noreply, assign(socket, :rows, call_tool(socket, "x/list", %{}))}
      end

      def handle_event("safe", _params, socket) do
        CyfrWeb.ContextGuard.guard(socket, fn socket -> {:noreply, reload(socket)} end)
      end

      def handle_event("ui", _params, socket), do: {:noreply, assign(socket, :open, true)}

      defp reload(socket), do: assign(socket, :rows, socket.assigns.context)
    end
    """

    assert [{:handle_event, 4}] = unguarded_callbacks(planted)
  end

  test "the drift check fails a callback that acts on the context in a branch outside the guard" do
    planted = """
    defmodule PrismWeb.PlantedBranch do
      use PrismWeb, :live_component

      def handle_event("go", %{"now" => now}, socket) do
        if now == "yes" do
          {:noreply, assign(socket, :rows, call_tool(socket, "x/list", %{}))}
        else
          CyfrWeb.ContextGuard.guard(socket, fn socket -> {:noreply, socket} end)
        end
      end

      def update(assigns, socket) do
        socket = assign(socket, assigns)
        {:noreply, socket} = CyfrWeb.ContextGuard.guard(socket, &{:noreply, reload(&1)})
        {:ok, socket}
      end

      defp reload(socket), do: assign(socket, :rows, socket.assigns.context)
    end
    """

    assert [{:handle_event, 4}] = unguarded_callbacks(planted)
  end

  # The `handle_event` and `update` clauses that act on the context —
  # directly, or through a local helper that does — anywhere outside a
  # `CyfrWeb.ContextGuard.guard/2` call.
  defp unguarded_callbacks(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    defs = definitions(ast)

    helpers =
      Enum.reduce(defs, %{}, fn
        {:defp, name, body, _line}, acc -> Map.update(acc, name, [body], &[body | &1])
        _def, acc -> acc
      end)

    tainted = taint(helpers, MapSet.new())

    for {:def, name, body, line} <- defs,
        name in [:handle_event, :update],
        acts?(outside_guard(body), tainted),
        do: {name, line}
  end

  defp definitions(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {kind, meta, [{:when, _, [{name, _, _} | _]} | body]} = node, acc
        when kind in [:def, :defp] ->
          {node, [{kind, name, body, meta[:line]} | acc]}

        {kind, meta, [{name, _, _} | body]} = node, acc
        when kind in [:def, :defp] and is_atom(name) ->
          {node, [{kind, name, body, meta[:line]} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp taint(helpers, tainted) do
    next =
      for {name, bodies} <- helpers,
          Enum.any?(bodies, &acts?(&1, tainted)),
          into: MapSet.new(),
          do: name

    if MapSet.equal?(next, tainted), do: tainted, else: taint(helpers, next)
  end

  defp acts?(body, tainted) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {{:., _, [_, field]}, _, _} = node, acc ->
          {node, acc or field in @context_markers}

        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, acc or name in @context_markers or MapSet.member?(tainted, name)}

        {name, _, scope} = node, acc when is_atom(name) and is_atom(scope) ->
          {node, acc or name == :ctx}

        node, acc when is_atom(node) ->
          {node, acc or node in @context_markers}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # The body with every `CyfrWeb.ContextGuard.guard/2` call cut out: what
  # is left runs whether or not the context stands.
  defp outside_guard(body) do
    Macro.prewalk(body, fn
      {{:., _, [{:__aliases__, _, [:CyfrWeb, :ContextGuard]}, :guard]}, _, _} -> :guarded
      node -> node
    end)
  end
end
