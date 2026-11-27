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
  What holds a machine's memory now, a line each, the largest first: a
  named holder by its name, its holdings on that machine as one, and the
  rest by kind and count. Each line carries the name it is for, or nil.
  """
  @spec holders([map()]) :: [%{name: String.t() | nil, text: String.t()}]
  def holders(holders) do
    {named, unnamed} = Enum.split_with(holders, &is_binary(&1.name))

    by_name =
      named
      |> Enum.group_by(& &1.name, & &1.bytes)
      |> Enum.map(fn {name, sizes} -> {name, Enum.sum(sizes), nil} end)

    by_kind =
      unnamed
      |> Enum.group_by(& &1.kind, & &1.bytes)
      |> Enum.map(fn {kind, sizes} -> {nil, Enum.sum(sizes), {kind, length(sizes)}} end)

    (by_name ++ by_kind)
    |> Enum.sort_by(fn {name, bytes, kind} -> {-bytes, name || "", kind} end)
    |> Enum.map(fn
      {name, bytes, nil} -> %{name: name, text: "#{name} uses #{size(bytes)}"}
      {nil, bytes, {kind, 1}} -> %{name: nil, text: "A #{kind(kind)} uses #{size(bytes)}"}
      {nil, bytes, {kind, n}} -> %{name: nil, text: "#{n} #{kinds(kind)} use #{size(bytes)}"}
    end)
  end

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
  some of it was last counted when the oldest of them last answered, and
  may be out of date; with no machine answering, when it was counted. Nil
  when every endpoint answered.
  """
  @spec stale(%{machines: [map()], unanswered: [map()]}) :: String.t() | nil
  def stale(%{unanswered: []}), do: nil

  def stale(%{machines: machines, unanswered: silent}) do
    at = silent |> Enum.map(& &1.heard_at) |> Enum.min(DateTime) |> clock()

    case machines do
      [] -> "Counted at #{at}, and may be out of date."
      _answered -> "Some of it was last counted at #{at}, and may be out of date."
    end
  end

  @doc "An endpoint that has not answered within three polls, by its name, for the administrator."
  @spec silent(%{endpoint: String.t(), heard_at: DateTime.t()}) :: String.t()
  def silent(%{endpoint: name, heard_at: at}), do: "#{name} has not answered since #{clock(at)}."

  defp clock(at), do: Calendar.strftime(at, "%H:%M UTC")

  @doc "What a person calls a kind of holder (`Prima.LocusPool.holder_words/1`)."
  @spec kind(atom()) :: String.t()
  def kind(kind), do: elem(Prima.LocusPool.holder_words(Atom.to_string(kind)), 0)

  defp kinds(kind), do: elem(Prima.LocusPool.holder_words(Atom.to_string(kind)), 1)

  @doc "A size as the pages spell it."
  @spec size(non_neg_integer()) :: String.t()
  def size(bytes), do: Prima.Bytes.format(bytes)

  @doc "Memory over a day's time, in MB-hours."
  @spec over_time(non_neg_integer()) :: String.t()
  def over_time(mib_ms) do
    hours = mib_ms / 3_600_000

    if hours >= 10,
      do: "#{round(hours)} MB-hours",
      else: "#{Float.round(hours, 1)} MB-hours"
  end

  @doc "How long a day's use was measured."
  @spec measured(non_neg_integer()) :: String.t()
  def measured(ms) when ms < 60_000, do: "#{div(ms, 1_000)} s"
  def measured(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)} min"

  def measured(ms) do
    case rem(div(ms, 60_000), 60) do
      0 -> "#{div(ms, 3_600_000)} h"
      minutes -> "#{div(ms, 3_600_000)} h #{minutes} min"
    end
  end

  @doc """
  How often a day's work was ended for memory, by cause, in the words a
  person read where it ended: what needed more than one piece of work may
  use, what CYFR ran out of memory for, and what ran out of memory where
  CYFR could not tell why.
  """
  @spec ended(%{cap: non_neg_integer(), machine: non_neg_integer(), either: non_neg_integer()}) ::
          [String.t()]
  def ended(ended) do
    for {cause, words} <- [
          cap: "needed more than one piece of work may use",
          machine: "CYFR ran out of memory",
          either: "ran out of memory, and CYFR could not tell why"
        ],
        count = Map.fetch!(ended, cause),
        count > 0,
        do: "#{count} × #{words}"
  end
end
