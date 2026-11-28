# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Telemetry.EmitterDriftTest do
  @moduledoc """
  Telemetry does not cross a process boundary, so an event is heard only
  in the VM that emits it, and every consumer of `Cyfr.Telemetry.Catalog`
  attaches in the control plane's VM, the operator's own attach among
  them. So every event is emitted by a module the control plane's release
  holds: the host's own (`apps/cyfr/lib`) or one of the two applications
  below it (`apps/arca/lib`, `apps/sanctum/lib`), which start in the same
  VM. Nothing else emits one: the contracts run in both VMs, Locus's nodes
  have no one listening, and a runner is a program of its own. The
  runner's operator events are `Prima.RunnerControl`'s roster: the
  catalog's `[:cyfr, :locus, :runtime, …]` events are exactly it, each
  for the operator alone, and the control plane emits each as a runner's
  worker service reports it (`Opus.Host.RunnerEvents`).

  An event is emitted by a file whose code passes it to `:telemetry.execute`
  or `:telemetry.span`, as a literal list or a module attribute holding
  one, or, for a family held to the one list of its kinds, as the
  family's prefix and a variable kind in the canonical form
  `Cyfr.Test.TelemetryFamilies` states, which emits every event of the
  family; a variable kind outside that form is an unbounded producer,
  refused naming its file and line; a file whose code passes anything
  else (a variable, a call) is read as emitting every event its code
  spells. Documentation and comments are
  not code, so an event a moduledoc mentions is not emitted by it.

  The rule is checked on the tree, and on planted violations, each of
  which it must refuse.
  """

  use ExUnit.Case, async: true

  # Every input is the same on both adapters (`Arca.Test.Adapter`).
  @moduletag :sqlite

  alias Cyfr.Telemetry.Catalog
  alias Prima.RunnerControl

  # apps/cyfr/test/cyfr/telemetry -> umbrella root
  @root Path.expand("../../../../..", __DIR__)

  # The three libs the control plane's release holds; telemetry does not
  # cross a process boundary, and these three share one VM.
  @control_plane ["apps/cyfr/lib", "apps/arca/lib", "apps/sanctum/lib"]
  # Where a planted control-plane emission goes, when a case needs one.
  @host "apps/cyfr/lib"
  @emitting [:execute, :span]

  # ---------------------------------------------------------------------------
  # The rule
  # ---------------------------------------------------------------------------

  # `emitted` maps each app lib directory to the set of events its code
  # emits. Answers every breach of the rule, empty when it holds.
  defp violations(catalog, emitted) do
    control_plane =
      @control_plane
      |> Enum.map(&Map.get(emitted, &1, MapSet.new()))
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    unheard =
      for {event, %{consumers: consumers}} <- catalog,
          consumers -- [:operator] != [],
          not MapSet.member?(control_plane, event),
          do: {:consumed_in_the_control_plane_but_emitted_elsewhere, event}

    runners = for {[:cyfr, :locus, :runtime | _] = event, _entry} <- catalog, do: event
    roster = Enum.map(RunnerControl.event_roster(), &runner_event/1)

    off_roster =
      for event <- runners -- roster, do: {:a_runner_event_off_its_control_channel_roster, event}

    uncatalogued =
      for event <- roster -- runners, do: {:a_runner_event_of_the_roster_not_catalogued, event}

    runner_events =
      Enum.flat_map(runners -- (runners -- roster), fn event ->
        consumers = catalog |> Map.fetch!(event) |> Map.fetch!(:consumers)

        [
          if(consumers -- [:operator] != [],
            do: {:a_runner_event_with_a_consumer_but_the_operator, event}
          ),
          if(not MapSet.member?(control_plane, event),
            do: {:a_runner_event_the_control_plane_does_not_emit, event}
          )
        ]
      end)

    elsewhere =
      for {lib, events} <- emitted,
          lib not in @control_plane,
          event <- events,
          do: {:emitted_outside_the_control_plane, lib, event}

    Enum.reject(unheard ++ off_roster ++ uncatalogued ++ runner_events ++ elsewhere, &is_nil/1)
  end

  # The event a runner's roster name (`"http.request"`) is emitted as.
  defp runner_event(%{name: name}),
    do: [:cyfr, :locus, :runtime | Enum.map(String.split(name, "."), &String.to_atom/1)]

  # ---------------------------------------------------------------------------
  # Reading what code emits
  # ---------------------------------------------------------------------------

  # Each app's lib and the events its code emits.
  defp emitted_by_tree do
    for lib <- Prima.Test.SourceTree.app_libs(@root),
        path <- @root |> Path.join(lib) |> Path.join("**/*.ex") |> Path.wildcard(),
        reduce: Map.new(Prima.Test.SourceTree.app_libs(@root), &{&1, MapSet.new()}) do
      emitted ->
        events = emitted_by_quoted(Prima.Test.SourceTree.quoted(path), path)
        Map.update!(emitted, lib, &MapSet.union(&1, events))
    end
  end

  # Every unbounded family producer in the apps' libs, by file and line.
  defp unbounded_by_tree do
    for lib <- Prima.Test.SourceTree.app_libs(@root),
        path <- @root |> Path.join(lib) |> Path.join("**/*.ex") |> Path.wildcard(),
        message <- families(Prima.Test.SourceTree.quoted(path), path).unbounded,
        do: message
  end

  defp families(ast, path),
    do: Cyfr.Test.TelemetryFamilies.scan(ast, Path.relative_to(path, @root))

  # The events a planted file's code emits.
  defp emitted_by_source(source),
    do: emitted_by_quoted(Code.string_to_quoted!(source), "planted.ex")

  # The events one file's code emits.
  defp emitted_by_quoted(ast, path) do
    attributes = attributes(ast)

    {_ast, {emits, dynamic?}} =
      Macro.prewalk(ast, {MapSet.new(), false}, fn
        {{:., _, [:telemetry, fun]}, _, [first | _]} = node, {emits, dynamic?}
        when fun in @emitting ->
          case event_of(first, attributes) do
            {:ok, event} -> {node, {MapSet.put(emits, event), dynamic?}}
            :family -> {node, {emits, dynamic?}}
            :error -> {node, {emits, true}}
          end

        node, acc ->
          {node, acc}
      end)

    emits = MapSet.union(emits, MapSet.new(families(ast, path).events))

    if dynamic?, do: MapSet.union(emits, spelled(ast)), else: emits
  end

  # A family-shaped event is the shared rule's to read
  # (`Cyfr.Test.TelemetryFamilies.scan/2`), canonical or unbounded.
  defp event_of(list, _attributes) when is_list(list) do
    cond do
      event?(list) -> {:ok, list}
      Cyfr.Test.TelemetryFamilies.family_shaped?(list) -> :family
      true -> :error
    end
  end

  defp event_of({:@, _, [{name, _, context}]}, attributes) when is_atom(context),
    do: Map.fetch(attributes, name)

  defp event_of(_expression, _attributes), do: :error

  # The module attributes a file sets to an event.
  defp attributes(ast) do
    {_ast, attributes} =
      Macro.prewalk(ast, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_list(value) ->
          if event?(value), do: {node, Map.put(acc, name, value)}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    attributes
  end

  # Every event a file's code spells.
  defp spelled(ast) do
    {_ast, events} =
      Macro.prewalk(ast, MapSet.new(), fn
        list, acc when is_list(list) ->
          if event?(list), do: {list, MapSet.put(acc, list)}, else: {list, acc}

        node, acc ->
          {node, acc}
      end)

    events
  end

  defp event?([:cyfr, _ | _] = list), do: Enum.all?(list, &is_atom/1)
  defp event?(_list), do: false

  # ---------------------------------------------------------------------------
  # The tree
  # ---------------------------------------------------------------------------

  # The tree is read once for every case that holds it to the rule or
  # plants a violation in it.
  setup_all do
    {:ok, tree: emitted_by_tree(), unbounded: unbounded_by_tree()}
  end

  test "the tree holds the rule", %{tree: tree, unbounded: unbounded} do
    assert violations(Catalog.all(), tree) == []
    assert unbounded == []
  end

  test "the runner's events are its control channel's roster, emitted by the control plane " <>
         "for the operator alone, and the audit hears none of them",
       %{tree: emitted} do
    roster = Enum.map(RunnerControl.event_roster(), &runner_event/1)
    catalogued = for {[:cyfr, :locus, :runtime | _] = event, _entry} <- Catalog.all(), do: event

    assert Enum.sort(catalogued) == Enum.sort(roster)
    assert roster -- Catalog.consumed_by(:operator) == []

    assert Enum.map(RunnerControl.event_roster(), &Opus.Host.RunnerEvents.event(&1.name)) ==
             roster

    assert Enum.all?(roster, &MapSet.member?(emitted["apps/cyfr/lib"], &1))

    for event <- Catalog.consumed_by(:audit) ++ Catalog.consumed_by(:bridge) do
      assert Enum.any?(@control_plane, &MapSet.member?(emitted[&1], event)), inspect(event)
      refute event in roster, inspect(event)
    end

    # The credential trail is the control plane's.
    assert [:cyfr, :opus, :secret, :dispensed] in Catalog.consumed_by(:audit)
    assert [:cyfr, :opus, :secret, :denied] in Catalog.consumed_by(:audit)
  end

  # ---------------------------------------------------------------------------
  # Reading code
  # ---------------------------------------------------------------------------

  test "an event is emitted by a literal, an attribute, or any event a dynamic emitter spells" do
    literal = """
    defmodule A do
      @moduledoc "Mentions [:cyfr, :doc, :only] and emits nothing of it."
      def f, do: :telemetry.execute([:cyfr, :a, :literal], %{}, %{})
      def g, do: :telemetry.attach("h", [:cyfr, :a, :attached], &IO.inspect/4, nil)
    end
    """

    assert emitted_by_source(literal) == MapSet.new([[:cyfr, :a, :literal]])

    attribute = """
    defmodule B do
      @event [:cyfr, :b, :attribute]
      def f, do: :telemetry.span(@event, %{}, fn -> {:ok, %{}} end)
    end
    """

    assert emitted_by_source(attribute) == MapSet.new([[:cyfr, :b, :attribute]])

    dynamic = """
    defmodule C do
      @one [:cyfr, :c, :one]
      def f(event), do: :telemetry.execute(event, %{}, %{})
      def g, do: f([:cyfr, :c, :two])
    end
    """

    assert emitted_by_source(dynamic) == MapSet.new([[:cyfr, :c, :one], [:cyfr, :c, :two]])
  end

  # ---------------------------------------------------------------------------
  # Planted violations
  # ---------------------------------------------------------------------------

  # A family's producer emits its every kind only in the canonical form:
  # the kind a parameter of the clause, guarded by membership in the
  # family's list and never bound again. Each other form is refused by
  # its file and line, and emits nothing of the family.
  test "a variable kind in a family's place is accepted only under its list's guard" do
    shares = for kind <- Prima.ShareKinds.all(), do: [:cyfr, :sanctum, :share, kind]

    canonical = """
    defmodule Planted.Canonical do
      @kinds Prima.ShareKinds.all()
      defp announce(kind, id) when kind in @kinds,
        do: :telemetry.execute([:cyfr, :sanctum, :share, kind], %{count: 1}, %{id: id})
      def direct(kind) when is_atom(kind) and kind in Prima.ShareKinds.all(),
        do: :telemetry.execute([:cyfr, :sanctum, :share, kind], %{}, %{})
    end
    """

    assert emitted_by_source(canonical) == MapSet.new(shares)
    assert families(Code.string_to_quoted!(canonical), "planted.ex").unbounded == []

    for {source, line, why} <- [
          {"""
           defmodule Planted.Unlisted do
             def f do
               kind = :unlisted
               :telemetry.execute([:cyfr, :sanctum, :share, kind], %{}, %{})
             end
           end
           """, 4, "the kind kind is not a parameter of the clause"},
          {"""
           defmodule Planted.UnknownPrefix do
             @kinds Prima.ShareKinds.all()
             def f(kind) when kind in @kinds,
               do: :telemetry.execute([:cyfr, :planted, :family, kind], %{}, %{})
           end
           """, 4, "no family has the prefix [:cyfr, :planted, :family]"},
          {"""
           defmodule Planted.Rebound do
             @kinds Prima.ShareKinds.all()
             def f(kind) when kind in @kinds do
               kind = :unlisted
               :telemetry.execute([:cyfr, :sanctum, :share, kind], %{}, %{})
             end
           end
           """, 5, "the kind kind is bound again in the clause"},
          {"""
           defmodule Planted.OtherList do
             def f(kind) when kind in [:created, :unlisted] or is_atom(kind),
               do: :telemetry.execute([:cyfr, :sanctum, :share, kind], %{}, %{})
           end
           """, 3, "the kind kind is not guarded by membership in its family's list"}
        ] do
      assert families(Code.string_to_quoted!(source), "planted.ex").unbounded == [
               "planted.ex:#{line}: unbounded family producer: #{why}"
             ]

      assert MapSet.disjoint?(emitted_by_source(source), MapSet.new(shares)), source
    end
  end

  test "a credential read audited in Locus is refused both ways", %{tree: tree} do
    # A Locus module emitting the credential read the control plane's
    # audit consumes: the audit attaches in the control plane's VM, so it
    # never hears the event.
    planted = """
    defmodule Locus.Runtime.Planted do
      def get(name) do
        :telemetry.execute([:cyfr, :opus, :secret, :accessed], %{}, %{secret_name: name})
      end
    end
    """

    catalog =
      Catalog.all()
      |> Map.delete([:cyfr, :opus, :secret, :dispensed])
      |> Map.put([:cyfr, :opus, :secret, :accessed], %{consumers: [:audit]})

    emitted =
      Map.update!(tree, "apps/locus/lib", &MapSet.union(&1, emitted_by_source(planted)))

    assert {:consumed_in_the_control_plane_but_emitted_elsewhere,
            [:cyfr, :opus, :secret, :accessed]} in violations(catalog, emitted)

    assert {:emitted_outside_the_control_plane, "apps/locus/lib",
            [:cyfr, :opus, :secret, :accessed]} in violations(catalog, emitted)
  end

  test "an audited event the control plane stops emitting is refused", %{tree: tree} do
    emitted =
      Map.update!(tree, @host, fn events ->
        MapSet.delete(events, [:cyfr, :opus, :secret, :dispensed])
      end)

    assert violations(Catalog.all(), emitted) == [
             {:consumed_in_the_control_plane_but_emitted_elsewhere,
              [:cyfr, :opus, :secret, :dispensed]}
           ]
  end

  test "a runner event off the roster, one of the roster not catalogued, heard beyond the " <>
         "operator or not emitted by the control plane, is refused",
       %{tree: tree} do
    planted = [:cyfr, :locus, :runtime, :planted, :call]
    off = Map.put(Catalog.all(), planted, %{consumers: [:operator], note: "planted"})

    assert violations(off, Map.update!(tree, @host, &MapSet.put(&1, planted))) == [
             {:a_runner_event_off_its_control_channel_roster, planted}
           ]

    event = [:cyfr, :locus, :runtime, :formula, :spawn]

    assert violations(Map.delete(Catalog.all(), event), tree) == [
             {:a_runner_event_of_the_roster_not_catalogued, event}
           ]

    audited = Map.update!(Catalog.all(), event, &%{&1 | consumers: [:audit]})

    assert violations(audited, tree) == [
             {:a_runner_event_with_a_consumer_but_the_operator, event}
           ]

    gone = Map.update!(tree, @host, &MapSet.delete(&1, event))

    assert violations(Catalog.all(), gone) == [
             {:a_runner_event_the_control_plane_does_not_emit, event}
           ]
  end

  test "an event emitted by the contracts or by Locus is refused", %{tree: tree} do
    event = [:cyfr, :opus, :emit]

    for lib <- ["apps/prima/lib", "apps/locus/lib"] do
      emitted = Map.update!(tree, lib, &MapSet.put(&1, event))

      assert violations(Catalog.all(), emitted) == [
               {:emitted_outside_the_control_plane, lib, event}
             ]
    end
  end
end
