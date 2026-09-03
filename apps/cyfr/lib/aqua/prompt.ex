# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Prompt do
  @moduledoc """
  The whole system prompt for one turn, composed in one place.

  It used to be four contributions concatenated at the call site —
  `Aqua.AgentConfig.build_system_prompt/2`, `Aqua.Actions.system_prelude/1`,
  a group prelude in `Aqua.Turn`, and the tool surface injected separately
  into the formula input. Nothing owned the result, so nothing could check
  it against what the turn may actually do.

  That is not a tidiness complaint. The runtime section announced
  `data/ for user storage, components/ for installed components` from the
  storage layout — the same sentence for every turn, whether or not the
  consent edge granted a single path. A model told it has files will try to
  read them, fail, and improvise around the failure; the honest prompt is
  the one derived from the authority the turn is actually rooted at.

  ## What it takes, and why each

    * `agent` — the resolved orchestrator: its authored prompt, its policy.
    * `authority` — what the consent edge grants. The only source for what
      the prompt may claim the agent can reach.
    * `owner` / `focus` — whose agent this is, and whose estate it is
      working in. Equal today. When an agent belongs to a person rather
      than an estate, the difference is the whole point: Tom in Acme has
      Tom's prompt and Acme's files, and the prompt has to say so rather
      than let the model assume its own tree is here.

  The estate's notes come last: its pinned page (short, read every turn)
  and the index of what is filed, read through `Aqua.Notes` under the
  focus — the room's pile in a room, the person's own in their own
  athanor. Sorted and free of timestamps, so everything before it is the
  same bytes turn after turn.
  """

  alias Sanctum.Context

  @type opts :: [
          agent: map(),
          authority: term() | nil,
          owner: String.t() | nil,
          focus: String.t() | nil,
          several_people?: boolean()
        ]

  @doc """
  Compose the system prompt for a turn.

  `:agent` is required; everything else narrows what the prompt claims.
  A nil `:authority` means the caller could not resolve one — the prompt
  then claims no capabilities at all, which is the fail-closed reading.
  """
  @spec compose(Context.t(), opts()) :: String.t()
  def compose(%Context{} = ctx, opts) do
    agent = Keyword.fetch!(opts, :agent)
    authority = Keyword.get(opts, :authority)
    tool_policy = agent["tool_policy"] || %{}

    IO.iodata_to_binary([
      base(ctx, agent),
      "\n\n---\n\n## Runtime Context\n\n",
      runtime(authority),
      working_in(opts),
      Aqua.Actions.system_prelude(tool_policy),
      several_people(Keyword.get(opts, :several_people?, false)),
      scrolls(ctx),
      notes(ctx)
    ])
  end

  # ---------------------------------------------------------------------------
  # Sections
  # ---------------------------------------------------------------------------

  # Read from the agent's OWN tree. An agent belongs to the estate whose
  # `aqua/` holds it, and a personal one working in a group would otherwise
  # have its prompt looked up in the group — finding a different agent of
  # the same name, or none, and running on the generic fallback. The
  # narrowing goes through the refocus chokepoint; an unreachable owner
  # falls back to the focus read and its documented generic fallback.
  defp base(ctx, %{"name" => name} = agent) do
    read_ctx =
      with owner when is_binary(owner) <- agent["owner"],
           {:ok, refocused} <- Context.refocus(ctx, owner) do
        refocused
      else
        _ -> ctx
      end

    Aqua.AgentConfig.base_prompt(read_ctx, name)
  end

  defp runtime(authority) do
    now = DateTime.utc_now()

    [
      "Current date: ",
      Calendar.strftime(now, "%Y-%m-%d"),
      ", ",
      Calendar.strftime(now, "%A"),
      ", ",
      Calendar.strftime(now, "%H:%M UTC"),
      "\n",
      file_paths(authority)
    ]
  end

  # Only the scopes this authority actually grants. The scope NAMES are
  # still the layout's (`Arca.Storage.guest_scopes/0`), so a renamed scope
  # moves the prompt with it; what changed is that a turn granted nothing
  # is no longer told it has everything.
  defp file_paths(authority) do
    case granted_paths(authority) do
      [] ->
        "File paths: none — this turn has no file access."

      scopes ->
        descriptions = %{"data" => "user storage", "components" => "installed components"}

        [
          "File paths: ",
          Enum.map_join(scopes, ", ", fn scope ->
            "#{scope}/ for #{Map.get(descriptions, scope, "guest storage")}"
          end)
        ]
    end
  end

  defp granted_paths(nil), do: []

  defp granted_paths(authority) do
    known = Arca.Storage.guest_scopes() |> Map.keys() |> Enum.sort(:desc)

    case authority do
      %{resources: %{storage: %{paths: paths}}} when is_list(paths) and paths != [] ->
        Enum.filter(known, fn scope -> Enum.any?(paths, &scope_granted?(&1, scope)) end)

      _ ->
        []
    end
  end

  # A granted path names a scope when it IS that scope or sits under it.
  # `"**"` is the whole tree, so every scope is reachable.
  defp scope_granted?("**", _scope), do: true
  defp scope_granted?(path, scope), do: path == scope or String.starts_with?(path, scope <> "/")

  # Whose agent, whose estate. Silent when they are the same, which is
  # every turn until agents belong to people — a sentence that always says
  # "you are working in your own estate" is a sentence nobody reads.
  defp working_in(opts) do
    owner = Keyword.get(opts, :owner)
    focus = Keyword.get(opts, :focus)

    if is_binary(owner) and is_binary(focus) and owner != focus do
      "\n\nYou are working in another estate than your own. Its files, its " <>
        "credentials and its components are what you have here; your own are not " <>
        "reachable from this conversation."
    else
      []
    end
  end

  # Several people are speaking, so the task prefixes each line with a name
  # and the prompt says so — otherwise the model reads a transcript as one
  # voice and answers the wrong person.
  @several_people "\n\nSeveral people are talking here. Each line of the task is prefixed " <>
                    "with the name of the person who said it, as `Name: text`. Address " <>
                    "people by name when it helps."

  defp several_people(true), do: @several_people
  defp several_people(_), do: []

  # The estate's scrolls — procedures kept as Agent Skills — as an index
  # of name and line, read on demand with `aqua.skill_get`. Sorted by
  # name and free of anything that changes between turns; an estate with
  # no scrolls gets no section rather than an empty one.
  defp scrolls(ctx) do
    case Aqua.AgentConfig.call_aqua(ctx, %{"action" => "skill_list"}) do
      {:ok, %{"skills" => [_ | _] = skills}} ->
        [
          "\n\n---\n\n## Scrolls\n\nProcedures this estate has learned. Read one with " <>
            "`aqua.skill_get` before doing what it describes; propose `aqua.skill_create` " <>
            "when a procedure worth repeating has just worked.\n",
          Enum.map(skills, fn %{"name" => name, "description" => description} ->
            ["- ", name, if(description == "", do: [], else: [" — ", description]), "\n"]
          end)
        ]

      _ ->
        []
    end
  end

  # The estate's notes, and the boundary said out loud. A room's turn is
  # told it sees the room's pile and nothing else; a turn in the person's
  # own athanor is told it may also search every estate they belong to.
  # The model never has to discover either by being refused.
  @notes_rule "These notes belong to the estate this conversation is in. Propose " <>
                "`notes.keep` for what people would want found again — a decision, a " <>
                "fact, a preference — and `notes.pin` only for what every future turn " <>
                "needs; never keep a secret or a credential. Read a filed note with " <>
                "`notes.read` before answering from your memory of it."

  @room_rule " Notes in other estates, and a person's own, are not readable from " <>
               "here — a person reads those from their own assistant."

  @home_rule " You may also search the notes of every estate this person belongs to " <>
               "(`notes.search` with scope `everywhere`)."

  defp notes(ctx) do
    rule = if Aqua.Notes.at_home?(ctx), do: @home_rule, else: @room_rule

    pinned =
      case Aqua.Notes.pinned(ctx) do
        {:ok, %{name: name, content: content}} -> ["\n\n### Pinned: ", name, "\n\n", content]
        :none -> []
      end

    index =
      case Aqua.Notes.index(ctx) do
        {:ok, []} ->
          "\n\nNo notes filed yet."

        {:ok, entries} ->
          [
            "\n\nFiled notes:\n",
            Enum.map(entries, fn %{name: name, line: line} ->
              ["- ", name, if(line == "", do: [], else: [" — ", line]), "\n"]
            end)
          ]

        {:error, _} ->
          []
      end

    ["\n\n---\n\n## Notes\n\n", @notes_rule, rule, pinned, index]
  end
end
