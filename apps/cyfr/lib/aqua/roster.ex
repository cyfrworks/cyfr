# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Roster do
  @moduledoc """
  Who is on a tape: the athanor's soul first, then its crew members — the
  tree in focus and no other. A person speaks to the room's soul, who
  hands a job to a member (`Aqua.Runner.Admission`); a person's own
  assistant lives in their own athanor and rides along in its own panel,
  never on a shared tape.
  """

  alias Sanctum.Context

  @doc """
  The roster as the console shows it: `name` and `title`
  per enabled agent. Fail-open BY CHOICE, and said in the log by the read
  itself: an unreadable tree reads as "nobody here" — the chat still
  renders, which beats refusing the whole thread for a catalog
  read. A soul whose file is refused still heads the roster, under its
  name, so the thread names who a post reaches; that turn says why it
  cannot answer.
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
end
