# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Roster do
  @moduledoc """
  Who can be addressed on a tape: the estate's soul first, then its
  roles — the tree in focus and no other. A room's tape is the room's:
  `@aqua` reaches the room's soul, and a role mention (`@builder`) runs
  that role directly for one turn; a person's own assistant lives in
  their own athanor and rides along in its own panel, never on a shared
  tape.
  """

  alias Sanctum.Context

  @doc """
  The roster as the console and the runner show it: `name` and `title`
  per enabled agent. Fail-open BY CHOICE, and said in the log by the read
  itself: an unreadable tree reads as "nobody here" — the chat still
  renders, which beats refusing the whole thread for a catalog
  read. A send with an empty roster and no prior pick is still refused
  `:no_orchestrator` by the runner.
  """
  @spec roster(Context.t()) :: [map()]
  def roster(%Context{} = ctx) do
    case Aqua.AgentConfig.roster(ctx) do
      {:ok, agents} ->
        Enum.map(agents, fn agent ->
          %{"name" => agent["name"], "title" => agent["title"] || agent["name"]}
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  An explicit `@name` in the message names the orchestrator for this turn
  — the roster entry called `name`. Returns `{message_without_mention,
  entry | nil}`: the whole entry, since the caller carries it into the
  turn. Matching longest-first, so a name that extends another's is
  never read as the shorter one with a suffix.
  """
  @spec parse_mention(String.t(), [map()]) :: {String.t(), map() | nil}
  def parse_mention(message, orchestrators) do
    if not String.contains?(message, "@") or orchestrators == [] do
      {message, nil}
    else
      orchestrators
      |> Enum.filter(&is_binary(&1["name"]))
      |> Enum.sort_by(&(-String.length(&1["name"])))
      |> Enum.find_value({message, nil}, fn %{"name" => name} = entry ->
        re = Regex.compile!("(?<![\\w@])@#{Regex.escape(name)}(?![\\w.-])", "i")

        if Regex.match?(re, message) do
          cleaned = Regex.replace(re, message, "") |> String.trim()
          {if(cleaned == "", do: message, else: cleaned), entry}
        end
      end)
    end
  end
end
