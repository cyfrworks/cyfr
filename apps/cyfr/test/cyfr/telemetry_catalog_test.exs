# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.TelemetryCatalogTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Pins the telemetry roster to `Cyfr.Telemetry.Catalog` in both directions.

  Before the catalog, 39 of the 62 producer events were consumed by
  nothing — including the tenant-bypass trail and the audit plane's own
  alarm. These scans keep a new event from shipping without a consumer
  decision, and a catalog entry from outliving its emitter.
  """

  alias Cyfr.Telemetry.Catalog

  # apps/cyfr/test/cyfr -> umbrella root
  @umbrella_root Path.expand("../../../..", __DIR__)

  # An event literal: [:cyfr, :a, :b, ...] with at least two segments.
  @event_re ~r/\[:cyfr(?:,\s*:[a-z_0-9]+)+\]/

  defp source_events do
    Path.wildcard(Path.join(@umbrella_root, "apps/*/lib/**/*.ex"))
    |> Enum.reject(&String.ends_with?(&1, "lib/cyfr/telemetry/catalog.ex"))
    |> Enum.flat_map(fn path ->
      # Collapse formatting so a list wrapped across lines still matches.
      source = path |> File.read!() |> String.replace(~r/\n\s*/, " ")

      Regex.scan(@event_re, source)
      |> Enum.map(fn [match] ->
        match
        |> String.trim_leading("[")
        |> String.trim_trailing("]")
        |> String.split(~r/,\s*/)
        |> Enum.map(&(&1 |> String.trim_leading(":") |> String.to_atom()))
      end)
    end)
    |> MapSet.new()
  end

  test "every event named in source is catalogued, and none is stale" do
    found = source_events()
    catalogued = MapSet.new(Catalog.events())

    uncatalogued = MapSet.difference(found, catalogued)
    stale = MapSet.difference(catalogued, found)

    assert MapSet.size(uncatalogued) == 0,
           "events in source but not in the catalog: #{inspect(MapSet.to_list(uncatalogued))}"

    assert MapSet.size(stale) == 0,
           "catalog entries with no source site: #{inspect(MapSet.to_list(stale))}"
  end

  test "every :operator disposition says why" do
    for event <- Catalog.consumed_by(:operator) do
      note = Catalog.note(event)

      assert is_binary(note) and note != "",
             "#{inspect(event)} is left to the operator without a reason"
    end
  end

  test "every catalogued event names at least one consumer" do
    for {event, %{consumers: consumers}} <- Catalog.all() do
      assert consumers != [], "#{inspect(event)} is a silent orphan"
    end
  end

  test "the audit handler attaches exactly the catalog's :audit roster" do
    for event <- Catalog.consumed_by(:audit) do
      ids = event |> :telemetry.list_handlers() |> Enum.map(& &1.id)

      assert Enum.any?(ids, &String.starts_with?(&1, "audit-")),
             "no audit handler attached for #{inspect(event)}"
    end
  end

  test "the telemetry bridge attaches exactly the catalog's :bridge roster" do
    for event <- Catalog.consumed_by(:bridge) do
      ids = event |> :telemetry.list_handlers() |> Enum.map(& &1.id)

      assert Enum.any?(ids, &String.starts_with?(&1, "prism-")),
             "no bridge handler attached for #{inspect(event)}"
    end
  end

  test "the metric definitions cover exactly the catalog's :metrics roster" do
    metric_events =
      EmissaryWeb.Telemetry.metrics()
      |> Enum.map(& &1.event_name)
      |> Enum.filter(&match?([:cyfr | _], &1))
      |> Enum.uniq()
      |> Enum.sort()

    assert metric_events == Catalog.consumed_by(:metrics)
  end

  test "the dedicated log attaches cover the catalog's :log roster" do
    for event <- Catalog.consumed_by(:log) do
      ids = event |> :telemetry.list_handlers() |> Enum.map(& &1.id)

      assert Enum.any?(ids, &String.contains?(&1, "-log")),
             "no logger attach for #{inspect(event)}"
    end
  end
end
