# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AgentsLive.Catalog do
  @moduledoc """
  Pure data transforms behind the Agents page: the tool/action catalog the
  capability matrix renders, kind classification, and the model-picker
  value codec. No `socket`, no markup.
  """

  require Logger

  @doc """
  Enumerate `(tool, [actions...])` from the live MCP registry — populated
  once per editor open, so the matrix UI can render real (tool, action)
  pairs the user can toggle. native_search is included as a bare key
  (no actions enum) since the formula treats it specially.

  Returns `[{tool, [{action, kind}]}]` merged across MCP tools, AQUA
  virtual tools, and external server tools. Every entry has a kind atom
  (`:read | :write | :execute | :destructive`) sourced from
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
              # External `server:tool` names never enter the registry cache
              # this enumerates, so enum-less tools can only be internal:
              # fall back to the default-meta entry when one exists.
              if default_meta do
                [{"_default", kind_from_meta(default_meta, name, "_default")}]
              else
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
      "[AgentsLive] Tool action `#{tool}.#{action}` has no kind annotation — defaulting to :write"
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

  @doc """
  Catalysts return their list-models response verbatim — typically a list
  of `%{"id" => ...}` objects, sometimes wrapped in a `{"data": [...]}`
  envelope. Reduce to a plain list of model ids.
  """
  def normalize_provider_models(value) do
    cond do
      is_list(value) -> Enum.map(value, &model_id/1) |> Enum.reject(&is_nil/1)
      is_map(value) and is_list(value["data"]) -> normalize_provider_models(value["data"])
      true -> []
    end
  end

  defp model_id(m) when is_binary(m), do: m
  defp model_id(%{"id" => id}) when is_binary(id), do: id
  defp model_id(%{id: id}) when is_binary(id), do: id
  defp model_id(_), do: nil
end
