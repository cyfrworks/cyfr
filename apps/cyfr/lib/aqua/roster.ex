# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Roster do
  @moduledoc """
  Who can be addressed on a tape: the athanor's soul first, then its
  crew members — the tree in focus and no other. A room's tape is the
  room's: `@aqua` reaches the room's soul, and a member's mention
  (`@explorer`) asks that member, who works in its child thread
  and replies on the room (`Aqua.Runner.Admission`); a person's own
  assistant lives in their own athanor and rides along in its own panel,
  never on a shared tape.
  """

  alias Sanctum.Context

  @doc """
  The roster as the console and the runner show it: `name` and `title`
  per enabled agent. Fail-open BY CHOICE, and said in the log by the read
  itself: an unreadable tree reads as "nobody here" — the chat still
  renders, which beats refusing the whole thread for a catalog
  read. A send with an empty roster and no prior pick is still refused
  `:no_agent` by the runner. A soul whose file is refused still heads
  the roster, under its name, so a post that names no one goes to it and
  its turn says why it cannot answer, never to a crew member in its place.
  """
  @spec roster(Context.t()) :: [map()]
  def roster(%Context{} = ctx) do
    case Aqua.AgentConfig.roster_and_soul(ctx) do
      {:ok, agents, soul_refused} ->
        listed = Enum.map(agents, &%{"name" => &1["name"], "title" => &1["title"]})

        if soul_refused,
          do: [%{"name" => Prima.AgentRef.soul_name(), "title" => "Aqua"} | listed],
          else: listed

      {:error, _} ->
        []
    end
  end

  @doc """
  An explicit `@name` in the message names the agent for this turn
  — the roster entry called `name`. Returns `{message_without_mention,
  entry | nil}`: the whole entry, since the caller carries it into the
  turn. Matching longest-first, so a name that extends another's is
  never read as the shorter one with a suffix.
  """
  @spec parse_mention(String.t(), [map()]) :: {String.t(), map() | nil}
  def parse_mention(message, agents) do
    if not String.contains?(message, "@") or agents == [] do
      {message, nil}
    else
      agents
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
