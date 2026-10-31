# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Telemetry.EmitterDriftTest do
  @moduledoc """
  Telemetry does not cross a process boundary, so an event is heard only
  in the VM that emits it, and `Cyfr.Telemetry.Catalog` says which VM that
  is. Every consumer but `:operator` attaches in the control plane's VM:
  an event one of them consumes (the audit trail and the console bridge
  among them) is emitted by a module the control plane's release holds:
  the host's own (`apps/cyfr/lib`) or one of the two applications below it
  (`apps/arca/lib`, `apps/sanctum/lib`), which start in the same VM. An
  event emitted under `apps/locus/lib/locus/runtime` runs in a runner, the OS
  process that runs a guest, and is rostered as the worker's
  (`emitter: :worker`), for the operator alone; one rostered so is emitted
  there and nowhere in the control plane. Nothing else emits an event: the
  contracts run in both VMs, and no one listens in the rest of Locus's.

  An event is emitted by a file whose code passes it to `:telemetry.execute`
  or `:telemetry.span`, as a literal list or a module attribute holding
  one, or, for a family held to the one list of its kinds
  (`Cyfr.Test.TelemetryFamilies`), as the family's prefix and a variable
  kind, which emits every event of the family; a file whose code passes
  anything else (a variable, a call) is read as emitting every event its
  code spells. Documentation and comments are
  not code, so an event a moduledoc mentions is not emitted by it.

  The rule is checked on the tree, and on planted violations, each of
  which it must refuse.
  """

  use ExUnit.Case, async: true

  alias Cyfr.Telemetry.Catalog

  # apps/cyfr/test/cyfr/telemetry -> umbrella root
  @root Path.expand("../../../../..", __DIR__)

  # The three libs the control plane's release holds; telemetry does not
  # cross a process boundary, and these three share one VM.
  @control_plane ["apps/cyfr/lib", "apps/arca/lib", "apps/sanctum/lib"]
  # Where a planted control-plane emission goes, when a case needs one.
  @host "apps/cyfr/lib"
  @worker "apps/locus/lib/locus/runtime"
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

    worker = Map.get(emitted, @worker, MapSet.new())
    rostered = for {event, entry} <- catalog, Map.get(entry, :emitter) == :worker, do: event

    unheard =
      for {event, %{consumers: consumers}} <- catalog,
          consumers -- [:operator] != [],
          not MapSet.member?(control_plane, event),
          do: {:consumed_in_the_control_plane_but_emitted_elsewhere, event}

    unrostered =
      for event <- worker,
          Map.get(Map.get(catalog, event, %{}), :emitter) != :worker,
          do: {:emitted_in_a_runner_but_not_rostered_as_the_workers, event}

    rostered_wrongly =
      Enum.flat_map(rostered, fn event ->
        consumers = catalog |> Map.fetch!(event) |> Map.fetch!(:consumers)

        [
          if(consumers -- [:operator] != [],
            do: {:rostered_as_the_workers_with_a_control_plane_consumer, event}
          ),
          if(not MapSet.member?(worker, event),
            do: {:rostered_as_the_workers_but_not_emitted_in_a_runner, event}
          ),
          if(MapSet.member?(control_plane, event),
            do: {:rostered_as_the_workers_but_emitted_by_the_control_plane, event}
          )
        ]
      end)

    elsewhere =
      for {lib, events} <- emitted,
          lib not in [@worker | @control_plane],
          event <- events,
          do: {:emitted_outside_the_control_plane_and_a_runner, lib, event}

    Enum.reject(unheard ++ unrostered ++ rostered_wrongly ++ elsewhere, &is_nil/1)
  end

  # ---------------------------------------------------------------------------
  # Reading what code emits
  # ---------------------------------------------------------------------------

  # Each app's lib, the runtime's tree keyed apart from the rest of
  # Locus's: the runtime's code runs in a runner, and the rest in a node.
  defp emitted_by_tree do
    worker = Path.join(@root, @worker) <> "/"

    for lib <- Prima.Test.SourceTree.app_libs(@root),
        path <- @root |> Path.join(lib) |> Path.join("**/*.ex") |> Path.wildcard(),
        reduce: Map.new(Prima.Test.SourceTree.app_libs(@root) ++ [@worker], &{&1, MapSet.new()}) do
      emitted ->
        key = if String.starts_with?(path, worker), do: @worker, else: lib
        events = emitted_by_source(Prima.Test.SourceTree.read(path))
        Map.update!(emitted, key, &MapSet.union(&1, events))
    end
  end

  # The events one source file's code emits.
  defp emitted_by_source(source) do
    ast = Code.string_to_quoted!(source)
    attributes = attributes(ast)

    {_ast, {emits, dynamic?}} =
      Macro.prewalk(ast, {MapSet.new(), false}, fn
        {{:., _, [:telemetry, fun]}, _, [first | _]} = node, {emits, dynamic?}
        when fun in @emitting ->
          case event_of(first, attributes) do
            {:ok, event} -> {node, {MapSet.put(emits, event), dynamic?}}
            {:family, events} -> {node, {MapSet.union(emits, MapSet.new(events)), dynamic?}}
            :error -> {node, {emits, true}}
          end

        node, acc ->
          {node, acc}
      end)

    if dynamic?, do: MapSet.union(emits, spelled(ast)), else: emits
  end

  defp event_of(list, _attributes) when is_list(list) do
    cond do
      event?(list) -> {:ok, list}
      events = family(list) -> {:family, events}
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

  # A family's prefix followed by a variable kind, as its producer passes it.
  defp family(list) do
    case Enum.split(list, -1) do
      {prefix, [{kind, _meta, context}]} when is_atom(kind) and is_atom(context) ->
        if Enum.all?(prefix, &is_atom/1), do: Cyfr.Test.TelemetryFamilies.events(prefix)

      _other ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # The tree
  # ---------------------------------------------------------------------------

  test "the tree holds the rule" do
    assert violations(Catalog.all(), emitted_by_tree()) == []
  end

  test "what a runner emits is the worker's roster, and the audit hears none of it" do
    emitted = emitted_by_tree()

    assert MapSet.to_list(emitted[@worker]) |> Enum.sort() == Catalog.emitted_by(:worker)
    assert Catalog.emitted_by(:worker) -- Catalog.consumed_by(:operator) == []

    for event <- Catalog.consumed_by(:audit) ++ Catalog.consumed_by(:bridge) do
      assert Enum.any?(@control_plane, &MapSet.member?(emitted[&1], event)), inspect(event)
      refute MapSet.member?(emitted[@worker], event), inspect(event)
    end

    # The credential trail is the control plane's, and nothing in a runner
    # emits a secret event.
    assert [:cyfr, :opus, :secret, :dispensed] in Catalog.consumed_by(:audit)
    assert [:cyfr, :opus, :secret, :denied] in Catalog.consumed_by(:audit)
    refute Enum.any?(emitted[@worker], &match?([:cyfr, :opus, :secret | _], &1))
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

  test "a credential read audited in the runner that reads it is refused both ways" do
    # A runner's vault import emitting the credential read the control
    # plane's audit consumes: the audit attaches in the control plane's VM,
    # so it never hears the event.
    runner = """
    defmodule Locus.Runtime.Engine do
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
      Map.update!(emitted_by_tree(), @worker, &MapSet.union(&1, emitted_by_source(runner)))

    assert {:consumed_in_the_control_plane_but_emitted_elsewhere,
            [:cyfr, :opus, :secret, :accessed]} in violations(catalog, emitted)

    assert {:emitted_in_a_runner_but_not_rostered_as_the_workers,
            [:cyfr, :opus, :secret, :accessed]} in violations(catalog, emitted)
  end

  test "an audited event the control plane stops emitting is refused" do
    emitted =
      Map.update!(emitted_by_tree(), @host, fn events ->
        MapSet.delete(events, [:cyfr, :opus, :secret, :dispensed])
      end)

    assert violations(Catalog.all(), emitted) == [
             {:consumed_in_the_control_plane_but_emitted_elsewhere,
              [:cyfr, :opus, :secret, :dispensed]}
           ]
  end

  test "a bridged event emitted only in a runner is refused" do
    event = [:cyfr, :locus, :runtime, :planted, :bridged]
    catalog = Map.put(Catalog.all(), event, %{consumers: [:bridge]})
    emitted = Map.update!(emitted_by_tree(), @worker, &MapSet.put(&1, event))

    assert {:consumed_in_the_control_plane_but_emitted_elsewhere, event} in violations(
             catalog,
             emitted
           )

    assert {:emitted_in_a_runner_but_not_rostered_as_the_workers, event} in violations(
             catalog,
             emitted
           )
  end

  test "a runner's event missing from the worker's roster, or rostered and unheard, is refused" do
    event = [:cyfr, :locus, :runtime, :formula, :spawn]

    unrostered = Map.update!(Catalog.all(), event, &Map.delete(&1, :emitter))

    assert violations(unrostered, emitted_by_tree()) == [
             {:emitted_in_a_runner_but_not_rostered_as_the_workers, event}
           ]

    audited = Map.update!(Catalog.all(), event, &%{&1 | consumers: [:audit]})

    assert {:rostered_as_the_workers_with_a_control_plane_consumer, event} in violations(
             audited,
             emitted_by_tree()
           )

    gone = Map.update!(emitted_by_tree(), @worker, &MapSet.delete(&1, event))

    assert violations(Catalog.all(), gone) == [
             {:rostered_as_the_workers_but_not_emitted_in_a_runner, event}
           ]

    both = Map.update!(emitted_by_tree(), @host, &MapSet.put(&1, event))

    assert violations(Catalog.all(), both) == [
             {:rostered_as_the_workers_but_emitted_by_the_control_plane, event}
           ]
  end

  test "an event emitted by the contracts or by Locus is refused" do
    event = [:cyfr, :opus, :emit]

    for lib <- ["apps/prima/lib", "apps/locus/lib"] do
      emitted = Map.update!(emitted_by_tree(), lib, &MapSet.put(&1, event))

      assert violations(Catalog.all(), emitted) == [
               {:emitted_outside_the_control_plane_and_a_runner, lib, event}
             ]
    end
  end
end
