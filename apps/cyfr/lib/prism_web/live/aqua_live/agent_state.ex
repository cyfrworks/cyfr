# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLive.AgentState do
  @moduledoc """
  Pure agent / approval / tool-action state transforms for `PrismWeb.AquaLive`.

  Every function here is a plain data transform — no `socket`, no assigns, no
  markup. Extracted from the LiveView to keep the surface small; behaviour is
  identical to the in-line versions.
  """

  require Logger

  @doc """
  True when an approval intent's `{tool, action}` proposal is in the
  conversation grant set (i.e. already auto-approved for this chat).
  """
  def proposal_granted?(%{proposal: %{tool: t, action: a}}, grants)
      when is_binary(t) and is_binary(a),
      do: MapSet.member?(grants, {t, a})

  def proposal_granted?(_, _), do: false

  # Surface suspicious dropped intents as in-chat system messages.
  # Currently only flags request_approval drops where the proposal violated
  # policy — those are the security-relevant ones. Routine drops (path not
  # in allowlist, malformed JSON) stay logger-only.
  def tripwire_messages(drops) do
    drops
    |> Enum.filter(&approval_tripwire?/1)
    |> Enum.map(fn %{reason: reason, raw: raw} ->
      proposal_label =
        case raw do
          %{"proposal" => %{"tool" => t, "action" => a}} -> "#{t}.#{a}"
          _ -> "(no proposal)"
        end

      %{
        role: "error",
        content: "⚠ Agent requested an action outside policy: #{proposal_label} — #{reason}",
        timestamp: DateTime.utc_now()
      }
    end)
  end

  defp approval_tripwire?(%{raw: %{"kind" => "ui.request_approval"}, reason: reason})
       when is_binary(reason) do
    reason =~ "allowlist"
  end

  defp approval_tripwire?(_), do: false

  @doc """
  Build the `{result_summary, system_text}` pair for a resolved approval.
  """
  def build_outcome_summary(:approved, %{result: result}, title, _proposal) do
    short = result_short(result)
    {short, "[System: user approved '#{title}'. Result: #{short}]"}
  end

  def build_outcome_summary(:declined, %{reason: reason}, title, _proposal) do
    txt =
      if reason && reason != "",
        do: "[System: user declined '#{title}'. Reason: #{reason}]",
        else: "[System: user declined '#{title}'.]"

    {reason, txt}
  end

  def build_outcome_summary(:error, %{reason: reason}, title, _proposal) do
    short = inspect(reason) |> String.slice(0, 200)
    {short, "[System: action '#{title}' failed: #{short}]"}
  end

  defp result_short(result) when is_map(result) do
    result
    |> Map.take([:status, "status", :id, "id", :name, "name"])
    |> case do
      empty when map_size(empty) == 0 -> "ok"
      m -> inspect(m) |> String.slice(0, 120)
    end
  end

  defp result_short(other), do: other |> inspect() |> String.slice(0, 120)

  @doc """
  Enumerate `(tool, [actions...])` from the live MCP registry — populated
  once per editor open, so the matrix UI can render real (tool, action)
  pairs the user can toggle. native_search is included as a bare key
  (no actions enum) since the formula treats it specially.

  Returns `[{tool, [{action, kind}]}]` merged across MCP tools, AQUA
  virtual tools, and external server tools. Every entry has a kind atom
  (`:read | :write | :execute | :destructive | :external`) sourced from
  `annotations.actions[verb].kind` (or `_default.kind` for opaque tools).
  Missing-annotation actions default to `:write` and are logged.
  """
  def enumerate_tool_actions do
    mcp =
      Emissary.MCP.ToolRegistry.list_tools()
      |> Enum.map(fn t ->
        name = t["name"]
        schema = t["inputSchema"] || %{}
        props = schema["properties"] || %{}
        action_enum = get_in(props, ["action", "enum"]) || []
        actions_meta = get_in(t, ["annotations", "actions"]) || %{}
        default_meta = actions_meta["_default"] || actions_meta[:_default]

        actions =
          case action_enum do
            [_ | _] = enum ->
              Enum.map(enum, fn a ->
                meta = actions_meta[a] || actions_meta[existing_atom(a)] || default_meta
                {a, kind_from_meta(meta, name, a)}
              end)

            _ when is_binary(name) ->
              cond do
                # External tools (`server:tool`) have no enumerable verbs and
                # are always `:external`. Represent the whole tool with a `*`
                # action so an allowlist entry (`"server:tool.*"`) matches any
                # real remote action via the glob fallback in `policy_value`.
                String.contains?(name, ":") ->
                  [{"*", :external}]

                # Other enum-less tools: fall back to the default-meta entry.
                default_meta ->
                  [{"_default", kind_from_meta(default_meta, name, "_default")}]

                true ->
                  []
              end

            _ ->
              []
          end

        {name, actions}
      end)

    virtual = Prism.AquaVirtualTools.list_for_panel()

    # `native_search` is a bare-tool exclusivity gate — has no actions but
    # appears in the policy as a single boolean key.
    (mcp ++ virtual ++ [{"native_search", []}])
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  Classify a tool-action annotation into its kind atom.
  """
  def kind_from_meta(%{kind: kind}, _tool, _action) when is_atom(kind), do: kind

  def kind_from_meta(%{"kind" => kind}, tool, action) when is_binary(kind) do
    case existing_atom(kind) do
      nil -> kind_from_meta(nil, tool, action)
      atom -> atom
    end
  end

  def kind_from_meta(_, tool, action) do
    Logger.warning(
      "[AquaLive] Tool action `#{tool}.#{action}` has no kind annotation — defaulting to :write"
    )

    :write
  end

  # Resolve a string to an already-existing atom, or `nil` when it isn't one.
  # Annotation verbs/kinds come from tool authors (including external MCP
  # servers), so never mint new atoms from them.
  @doc """
  Resolve a string to an already-existing atom, or `nil` when it isn't one.
  """
  def existing_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  def existing_atom(_), do: nil

  # Decode the model dropdown's combined "provider::model" value back into a
  # provider+model pair. "" = inherit from parent. Anything else = noop.
  @doc """
  Decode the model dropdown's combined `"provider::model"` value.
  """
  def decode_model_choice(""), do: {:inherit}

  def decode_model_choice(value) when is_binary(value) do
    case String.split(value, "::", parts: 2) do
      [provider, model] when provider != "" and model != "" -> {:model, provider, model}
      _ -> :noop
    end
  end

  def decode_model_choice(_), do: :noop

  @doc """
  Detect an explicit `@name` token in the user message and pull it out so
  the agent can route to the named orchestrator. Mirrors AgentLive's parser.
  """
  def parse_orchestrator_mention(message, orchestrators) do
    if not String.contains?(message, "@") or orchestrators == [] do
      {message, nil}
    else
      names = Enum.map(orchestrators, & &1["name"])
      sorted = Enum.sort_by(names, &(-String.length(&1)))

      Enum.find_value(sorted, {message, nil}, fn name ->
        re = Regex.compile!("@#{Regex.escape(name)}(?=\\s|$)", "i")

        if Regex.match?(re, message) do
          cleaned = Regex.replace(re, message, "") |> String.trim()
          {if(cleaned == "", do: message, else: cleaned), name}
        end
      end)
    end
  end
end
