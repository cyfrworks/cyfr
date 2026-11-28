# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Host.RunnerEvents do
  @moduledoc """
  The operator events a runner reports, emitted here, in the control
  plane, as each arrives in a worker service's `report_events` batch
  (`Opus.Host.events_report/2`): telemetry does not cross a process
  boundary, and a runner is a process of its own that emits none.

  `Prima.RunnerControl`'s roster names each event (`"http.request"`) with
  its measurements and metadata; it is emitted as the telemetry event
  this module spells for it (`[:cyfr, :locus, :runtime, :http,
  :request]`), which `Cyfr.Telemetry.Catalog` lists for the operator's
  own attach. Its measurements and metadata are the record's, keyed by
  their atoms, read two ways: a `system_time`, microseconds since the
  epoch on the runner's clock, is emitted in this VM's native unit, as
  `System.system_time/0` is; and a status word is its atom (`:ok`,
  `:timeout`, `:response_too_large`), an HTTP status staying an integer.
  """

  alias Prima.RunnerControl

  # Each event of the runner's roster and the telemetry event it is
  # emitted as. The roster is the authority: a name this table and the
  # roster do not share fails the compile.
  @events %{
    "engine.authority_entered" => [:cyfr, :locus, :runtime, :engine, :authority_entered],
    "http.request" => [:cyfr, :locus, :runtime, :http, :request],
    "storage.call" => [:cyfr, :locus, :runtime, :storage, :call],
    "mcp_tool.call" => [:cyfr, :locus, :runtime, :mcp_tool, :call],
    "formula.spawn" => [:cyfr, :locus, :runtime, :formula, :spawn],
    "formula.await" => [:cyfr, :locus, :runtime, :formula, :await],
    "formula.await_all" => [:cyfr, :locus, :runtime, :formula, :await_all],
    "formula.cancel" => [:cyfr, :locus, :runtime, :formula, :cancel],
    "formula.await_any" => [:cyfr, :locus, :runtime, :formula, :await_any]
  }

  @roster RunnerControl.event_roster()

  if Enum.sort(Map.keys(@events)) != Enum.sort(Enum.map(@roster, & &1.name)) do
    raise CompileError,
      description: "Opus.Host.RunnerEvents names other events than Prima.RunnerControl's roster"
  end

  words_of = fn
    {:one_of, words} -> words
    {:one_of, words, :http_status} -> words
    _type -> []
  end

  # Each event's metadata members that carry a status word, each with its
  # set's words as the atoms they are emitted as: made once, here, from
  # the roster's own sets, so no other string of a record is an atom.
  @worded Map.new(@roster, fn %{name: name, metadata: metadata} ->
            {name,
             for {member, type} <- metadata, words = words_of.(type), words != [], into: %{} do
               {member, Map.new(words, &{&1, String.to_atom(&1)})}
             end}
          end)

  @doc "The telemetry event the roster's event `name` is emitted as."
  @spec event(String.t()) :: [atom(), ...]
  def event(name) when is_map_key(@events, name), do: Map.fetch!(@events, name)

  @doc """
  Emit `events`, each an `event` the roster read
  (`Prima.RunnerControl.read_event/1`), in order.
  """
  @spec emit([RunnerControl.event()]) :: :ok
  def emit(events) when is_list(events) do
    Enum.each(events, fn %{type: :event, name: name, measurements: m, metadata: d} ->
      :telemetry.execute(event(name), measured(m), described(Map.fetch!(@worded, name), d))
    end)
  end

  defp measured(measurements) do
    Map.new(measurements, fn
      {:system_time, us} -> {:system_time, System.convert_time_unit(us, :microsecond, :native)}
      other -> other
    end)
  end

  # A status word is its atom; an HTTP status, and every other member,
  # is the record's own value.
  defp described(worded, metadata) do
    Map.new(metadata, fn {member, value} ->
      case worded do
        %{^member => words} -> {member, Map.get(words, value, value)}
        _not_a_status -> {member, value}
      end
    end)
  end
end
