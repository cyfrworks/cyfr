# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.MemoryWords do
  @moduledoc """
  The words the Programs and Settings pages say of who uses what memory
  (`Opus.memory/2`): a machine's heading, what holds its memory now, how
  fresh that is, and a day's use. Sizes are `Prima.Bytes.format/1`'s;
  times are said as the Programs page says them.
  """

  @doc """
  A machine's heading, by its name: `Machine <name>` where several
  machines answered, none where one did. An endpoint that has not
  answered is never a machine: the read does not say whose machine it is.
  """
  @spec heading(%{machines: [map()]}, String.t()) :: String.t() | nil
  def heading(%{machines: machines}, name) do
    if length(machines) > 1, do: "Machine " <> name
  end

  @doc """
  What holds a machine's memory now, a line each: a named holder by its
  name, its holdings on that machine as one, then the rest by kind and
  count in `Prima.LocusPool.holder_kinds/0`'s order. A line keeps its place
  when a size changes, so a control under the pointer stays where it is.
  Each line carries the name it is for, or nil.
  """
  @spec holders([map()]) :: [%{name: String.t() | nil, text: String.t()}]
  def holders(holders) do
    {named, unnamed} = Enum.split_with(holders, &is_binary(&1.name))

    by_name =
      named
      |> Enum.group_by(& &1.name, & &1.bytes)
      |> Enum.map(fn {name, sizes} -> {name, Enum.sum(sizes), nil} end)
      |> Enum.sort_by(fn {name, _bytes, nil} -> name end)

    by_kind =
      unnamed
      |> Enum.group_by(& &1.kind, & &1.bytes)
      |> Enum.map(fn {kind, sizes} -> {nil, Enum.sum(sizes), {kind, length(sizes)}} end)
      |> Enum.sort_by(fn {nil, _bytes, {kind, _n}} -> place(kind) end)

    (by_name ++ by_kind)
    |> Enum.map(fn
      {name, bytes, nil} -> %{name: name, text: "#{name} uses #{size(bytes)}"}
      {nil, bytes, {kind, 1}} -> %{name: nil, text: "A #{kind(kind)} uses #{size(bytes)}"}
      {nil, bytes, {kind, n}} -> %{name: nil, text: "#{n} #{kinds(kind)} use #{size(bytes)}"}
    end)
  end

  @doc """
  The administrator's rows of what holds a machine's memory: by person,
  then kind in `Prima.LocusPool.holder_kinds/0`'s order, then name, so a
  row keeps its place when a size changes.
  """
  @spec rows([map()]) :: [map()]
  def rows(holders) do
    Enum.sort_by(holders, &{&1.person.name || &1.person.athanor, place(&1.kind), &1.name || ""})
  end

  defp place(kind),
    do: Enum.find_index(Prima.LocusPool.holder_kinds(), &(&1 == Atom.to_string(kind)))

  @doc "Everyone else's use on a machine, or nil when it holds none."
  @spec others(map()) :: String.t() | nil
  def others(%{others: 0}), do: nil
  def others(%{others: bytes}), do: "Others use #{size(bytes)}."

  @doc "How fresh a machine's count is: it answered within three polls."
  @spec counted(map()) :: String.t()
  def counted(%{machine: _name}), do: "Counted a few seconds ago."

  @doc """
  What the person's own read says of its endpoints that have not answered
  within three polls, after what the machines that did answer hold: that
  some of it cannot be counted now, and when the oldest of them last
  answered; with no machine answering, that none of it can, and when it
  was last counted. Nil when every endpoint answered.
  """
  @spec stale(%{machines: [map()], unanswered: [map()]}) :: String.t() | nil
  def stale(%{unanswered: []}), do: nil

  def stale(%{machines: machines, unanswered: silent}) do
    at = silent |> Enum.map(& &1.heard_at) |> Enum.min(DateTime) |> clock()

    case machines do
      [] ->
        "What uses memory cannot be counted right now. It was last counted at #{at}."

      _answered ->
        "Some of it cannot be counted right now; that part was last counted at #{at}."
    end
  end

  @doc """
  An endpoint that has not answered within three polls, for the
  administrator, by the service it is: the builds'
  (`Prima.LocusPool.builds_endpoint/0`), the programs'
  (`Opus.Programs.local/0`), or a worker service's, by its id.
  """
  @spec silent(%{endpoint: String.t(), heard_at: DateTime.t()}) :: String.t()
  def silent(%{endpoint: name, heard_at: at}),
    do: "#{service(name)} has not answered since #{clock(at)}, so what it runs is not counted."

  defp service(name) do
    cond do
      name == Prima.LocusPool.builds_endpoint() -> "The service for builds"
      name == Opus.Programs.local() -> "The service for programs"
      true -> "The service for runs (#{name})"
    end
  end

  defp clock(at), do: Calendar.strftime(at, "%H:%M UTC")

  @doc "What a person calls a kind of holder (`Prima.LocusPool.holder_words/1`)."
  @spec kind(atom()) :: String.t()
  def kind(kind), do: elem(Prima.LocusPool.holder_words(Atom.to_string(kind)), 0)

  defp kinds(kind), do: elem(Prima.LocusPool.holder_words(Atom.to_string(kind)), 1)

  @doc "A size as the pages spell it."
  @spec size(non_neg_integer()) :: String.t()
  def size(bytes), do: Prima.Bytes.format(bytes)

  @doc """
  What a day's row used on average over the time it was measured, its
  MiB-milliseconds over its milliseconds; a dash where nothing was
  measured.
  """
  @spec average(%{mib_ms: non_neg_integer(), measured_ms: non_neg_integer()}) :: String.t()
  def average(%{measured_ms: 0}), do: "—"

  def average(%{mib_ms: mib_ms, measured_ms: ms}),
    do: "#{size(div(mib_ms * 1_048_576, ms))} on average"

  @doc """
  The most a day's row held at once, and for how long it was measured, as
  one line whose two halves each keep their words together (no-break
  spaces), so a narrow page breaks it between them and nowhere else.
  """
  @spec at_most(%{peak_bytes: non_neg_integer(), measured_ms: non_neg_integer()}) :: String.t()
  def at_most(%{peak_bytes: peak, measured_ms: ms}),
    do: together("at most #{size(peak)},") <> " " <> together("for #{duration(ms)}")

  defp together(words), do: String.replace(words, " ", "\u00a0")

  @doc "A length of time in words: under a second, seconds, minutes, or hours and minutes."
  @spec duration(non_neg_integer()) :: String.t()
  def duration(ms) when ms < 1_000, do: "under a second"
  def duration(ms) when ms < 60_000, do: count(div(ms, 1_000), "second")
  def duration(ms) when ms < 3_600_000, do: count(div(ms, 60_000), "minute")

  def duration(ms) do
    case rem(div(ms, 60_000), 60) do
      0 -> count(div(ms, 3_600_000), "hour")
      minutes -> count(div(ms, 3_600_000), "hour") <> " " <> count(minutes, "minute")
    end
  end

  defp count(1, unit), do: "1 " <> unit
  defp count(n, unit), do: "#{n} #{unit}s"

  @doc """
  How often a day's work was ended for memory, by cause, in the words a
  person read where it ended: what needed more memory than one piece of
  work may use, what CYFR ran out of memory for, and what ran out of memory where
  CYFR could not tell why.
  """
  @spec ended(%{cap: non_neg_integer(), machine: non_neg_integer(), either: non_neg_integer()}) ::
          [String.t()]
  def ended(ended) do
    for {cause, words} <- [
          cap: "needed more memory than one piece of work may use",
          machine: "CYFR ran out of memory",
          either: "ran out of memory, and CYFR could not tell why"
        ],
        count = Map.fetch!(ended, cause),
        count > 0,
        do: "#{count} × #{words}"
  end
end
