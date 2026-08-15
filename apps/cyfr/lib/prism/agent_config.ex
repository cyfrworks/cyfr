# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.AgentConfig do
  @moduledoc """
  Builds agent configuration for formula input by querying the `guide` MCP tool.

  All prompt and metadata access goes through the guide tool, which reads from
  `aqua/agent.json` at runtime. This ensures a single canonical API for both
  internal and external harnesses.
  """

  alias Sanctum.Context

  # Per-user approval grants live under the TENANT-scoped `aqua-grants/`
  # prefix, never in the shared agent.json: the manifest is instance-global
  # (Arca routes `aqua/` outside tenant segmentation), so one user's
  # "always approve" click must not change what the agent may do for
  # everyone else. The overlay is merged into the effective policy at
  # run/parse time only — manifest reads and the Agents editor stay pure.
  @grants_prefix "aqua-grants"

  @doc """
  The caller's personal approval overlay for `agent_name`:
  `%{"tool.action" => "auto" | "deny"}`. `"auto"` is a persisted
  "always approve"; `"deny"` a persisted "never".
  """
  def user_tool_grants(%Context{} = ctx, agent_name) do
    case Arca.get_json(ctx, grants_path(ctx)) do
      {:ok, %{} = grants} -> Map.get(grants, agent_name, %{})
      _ -> %{}
    end
  end

  @doc "Persist one per-user grant (`\"auto\"` or `\"deny\"`) for `agent_name`."
  def put_user_tool_grant(%Context{} = ctx, agent_name, key, mode)
      when is_binary(agent_name) and is_binary(key) and mode in ["auto", "deny"] do
    grants =
      case Arca.get_json(ctx, grants_path(ctx)) do
        {:ok, %{} = existing} -> existing
        _ -> %{}
      end

    updated = Map.update(grants, agent_name, %{key => mode}, &Map.put(&1, key, mode))
    Arca.put_json(ctx, grants_path(ctx), updated)
  end

  @doc """
  The manifest policy overlaid with the caller's personal grants:
  `"auto"` entries are added, `"deny"` entries removed (absence from the
  allowlist is what makes an action uncallable).
  """
  def effective_tool_policy(%Context{} = ctx, agent_name, manifest_policy)
      when is_map(manifest_policy) do
    {denies, autos} =
      ctx
      |> user_tool_grants(agent_name)
      |> Enum.split_with(fn {_k, mode} -> mode == "deny" end)

    manifest_policy
    |> Map.merge(Map.new(autos))
    |> Map.drop(Enum.map(denies, &elem(&1, 0)))
  end

  # One file per user; ids are `<provider>|<iss>|<sub>` so they are hashed
  # into a fixed-width filename instead of sanitized.
  defp grants_path(%Context{} = ctx) do
    user = ctx.user_id || "local"
    digest = Base.encode16(:crypto.hash(:sha256, user), case: :lower)
    [@grants_prefix, digest <> ".json"]
  end

  @doc """
  Load full config for an orchestrator (prompt content + resolved catalyst).

  Uses the guide tool to fetch prompt content and metadata. Resolves the
  versionless catalyst_ref to the latest installed version.
  """
  def orchestrator_config(%Context{} = ctx, agent_name \\ "aqua") do
    name = agent_name || "aqua"

    with {:ok, guide} <- call_guide(ctx, %{"action" => "get", "name" => name}),
         content when is_binary(content) <- guide["content"],
         catalyst_ref_raw <- guide["catalyst_ref"],
         {:ok, catalyst_ref} <- resolve_catalyst(ctx, catalyst_ref_raw) do
      {:ok,
       %{
         name: name,
         title: guide["title"],
         content: content,
         catalyst_ref: catalyst_ref,
         model: guide["model"],
         tool_policy: guide["tool_policy"] || %{}
       }}
    else
      nil -> {:error, :no_content}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Build sub-agent definitions for formula input.

  Fetches all sub-agents via the guide tool and resolves per-role
  catalyst/model (inheriting from the orchestrator when not set).
  """
  def sub_agent_definitions(%Context{} = ctx, agent_name, fallback_catalyst, fallback_model) do
    with {:ok, list_result} <- call_guide(ctx, %{"action" => "list", "type" => "sub-agent"}) do
      guides = extract_guides(list_result)

      # Filter to sub-agents belonging to this orchestrator
      parent_agents =
        guides
        |> Enum.filter(fn g ->
          parent = g["parent"]
          parent == agent_name
        end)

      parent_agents
      |> Enum.map(fn g ->
        name = g["name"]
        build_sub_agent(ctx, name, fallback_catalyst, fallback_model)
      end)
      |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  # --- Private helpers ---

  defp build_sub_agent(ctx, name, fallback_catalyst, fallback_model) do
    with {:ok, guide} <- call_guide(ctx, %{"action" => "get", "name" => name}) do
      content = guide["content"] || ""
      description = guide["description"] || ""
      title = guide["title"] || name
      tool_policy = guide["tool_policy"] || %{}
      raw_catalyst = guide["catalyst_ref"]
      raw_model = guide["model"]

      # Resolve per-role catalyst, falling back to orchestrator's
      {catalyst_ref, model} =
        resolve_role_model(ctx, raw_catalyst, raw_model, fallback_catalyst, fallback_model)

      %{
        "name" => name,
        "title" => title,
        "description" => description,
        "prompt" => content,
        "tool_policy" => tool_policy,
        "catalyst_ref" => catalyst_ref,
        "model" => model
      }
      |> put_formula_tool_surface(tool_policy)
    else
      _ -> nil
    end
  end

  @doc """
  Attach the formula's `tool_policy` allowlist
  (`{"tool.action" | "tool.*" => "ask" | "auto"}`) to an input/sub-agent map.

  The policy is the ONLY tool surface: it is always attached (an empty map
  when the agent carries none — the empty allowlist is the fail-closed
  default, never omission). The formula filters each tool's `action` enum to
  its directly-callable verbs (read-kind or `"auto"`), routes `"ask"` actions
  through the system-prompt approval prelude, and derives the provider-native
  search tool from a bare `"native_search"` policy key.
  """
  @spec put_formula_tool_surface(map(), map() | nil) :: map()
  def put_formula_tool_surface(input, tool_policy) when is_map(input) do
    Map.put(input, "tool_policy", tool_policy || %{})
  end

  defp resolve_role_model(ctx, catalyst_ref, model, fallback_catalyst, fallback_model) do
    if is_binary(catalyst_ref) and is_binary(model) do
      case resolve_catalyst(ctx, catalyst_ref) do
        {:ok, resolved} -> {resolved, model}
        _ -> {fallback_catalyst, fallback_model}
      end
    else
      {fallback_catalyst, fallback_model}
    end
  end

  @doc false
  def resolve_catalyst(%Context{} = ctx, versionless_ref) when is_binary(versionless_ref) do
    result =
      Emissary.MCP.ToolRegistry.call_external("component", ctx, %{
        "action" => "list",
        "type" => "catalyst"
      })

    case result do
      {:ok, listing} when is_map(listing) ->
        case stringify_deep(listing) do
          %{"components" => components} when is_list(components) ->
            find_matching_catalyst(components, versionless_ref)

          _ ->
            {:error, :catalyst_lookup_failed}
        end

      _ ->
        {:error, :catalyst_lookup_failed}
    end
  end

  def resolve_catalyst(_ctx, nil), do: {:error, :no_catalyst_ref}

  defp find_matching_catalyst(components, versionless_ref) do
    prefix = versionless_ref <> ":"

    match =
      components
      |> Enum.filter(fn c -> String.starts_with?(c["reference"] || "", prefix) end)
      |> Enum.max_by(fn c -> c["version"] || "0" end, fn -> nil end)

    case match do
      nil -> {:error, :catalyst_not_found}
      c -> {:ok, c["reference"]}
    end
  end

  defp call_guide(ctx, args) do
    case Emissary.MCP.ToolRegistry.call_external("aqua", ctx, args) do
      {:ok, result} -> {:ok, stringify_deep(result)}
      other -> other
    end
  end

  @doc """
  Deep-convert a tool result's keys to strings — one spelling on the way in.

  In-process tool providers return atom-keyed maps while wire round-trips
  return string keys; normalizing at the call boundary means every consumer
  reads exactly one spelling instead of carrying `m[:k] || m["k"]` pairs.
  """
  def stringify_deep(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify_deep(v)} end)

  def stringify_deep(list) when is_list(list), do: Enum.map(list, &stringify_deep/1)
  def stringify_deep(other), do: other

  defp extract_guides(%{"guides" => guides}) when is_list(guides), do: guides
  defp extract_guides(_), do: []

  # ============================================================================
  # System prompt composition
  # ============================================================================

  @doc """
  Build the full system prompt for an orchestrator: base prompt fetched
  via the guide tool, plus a runtime-context block (date, key paths)
  appended after a separator.

  Falls back to a generic prompt if the guide lookup fails — keeps the
  agent usable while AQUA configuration is still being set up.
  """
  @spec build_system_prompt(Context.t(), String.t()) :: String.t()
  def build_system_prompt(%Context{} = ctx, orchestrator_name \\ "aqua") do
    base = fetch_base_prompt(ctx, orchestrator_name)
    dynamic = build_dynamic_context(ctx)

    if dynamic != "",
      do: base <> "\n\n---\n\n## Runtime Context\n\n" <> dynamic,
      else: base
  end

  defp fetch_base_prompt(ctx, orchestrator_name) do
    case orchestrator_config(ctx, orchestrator_name) do
      {:ok, %{content: content}} ->
        content

      _ ->
        "You are an agent inside CYFR, a secure personal foundry that forges brilliance into reality."
    end
  end

  defp build_dynamic_context(_ctx) do
    now = DateTime.utc_now()
    day_name = Calendar.strftime(now, "%A")
    date_str = Calendar.strftime(now, "%Y-%m-%d")
    time_str = Calendar.strftime(now, "%H:%M UTC")

    "Current date: #{date_str}, #{day_name}, #{time_str}\n" <>
      "File paths: data/ for user storage, components/ for installed components"
  end
end
