# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.AgentConfig do
  require Logger

  @moduledoc """
  Builds agent configuration for formula input by querying the `aqua` MCP tool.

  All prompt and metadata access goes through the aqua tool, which reads the
  athanor's `aqua/` tree — the soul and its roles — at runtime. This ensures
  a single canonical API for both internal and external harnesses.
  """

  alias Sanctum.Context

  # The agent's `tool_policy` is DECLARED policy — what the agent's author
  # says it may do, edited on the agents page. A chat decision ("always
  # approve", "never ask again") is not an edit to it: those are
  # `Aqua.ToolGrants` rows, composed over this at use time. The two used to
  # share this storage, so clicking a button in one conversation rewrote
  # the agent's definition for every conversation and every member — and
  # once agents belong to people rather than estates, it would have
  # followed a borrowed agent home.

  @doc """
  Load full config for an orchestrator (prompt content + resolved catalyst).

  Uses the aqua tool to fetch prompt content and metadata. Resolves the
  versionless catalyst_ref to the latest installed version.
  """
  def orchestrator_config(%Context{} = ctx, agent_name \\ "aqua") do
    name = agent_name || "aqua"

    with {:ok, guide} <- call_aqua(ctx, %{"action" => "get", "name" => name}),
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
  The role definitions a turn hands the formula — the whole closet of the
  tree the running agent lives in, flat: a role has no roles of its own,
  and a soul spawns every role its estate keeps.

  `orchestrator` is the resolved agent (its `"owner"` names the tree). The
  GUIDES are read from that owner's tree, which is the focus for an
  estate's soul and the person's own athanor for their own — an estate's
  soul can never clone into a role that lives in someone's private tree.
  The CATALYSTS still resolve against `ctx` — components belong to the
  estate the turn runs in, not to the agent's owner.
  """
  def role_definitions(%Context{} = ctx, orchestrator, fallback_catalyst, fallback_model)
      when is_map(orchestrator) do
    read_ctx = owner_read_ctx(ctx, orchestrator["owner"])

    with {:ok, list_result} <- call_aqua(read_ctx, %{"action" => "list"}) do
      roles = list_result |> extract_guides() |> Enum.filter(&(&1["type"] == "role"))

      listing =
        case catalyst_listing(ctx) do
          {:ok, components} -> components
          # Fail-open by choice: no listing means sub-agents fall back to
          # the parent's catalyst rather than the roster refusing to build.
          _ -> []
        end

      roles
      |> Enum.map(fn g ->
        build_role(read_ctx, listing, g["name"], fallback_catalyst, fallback_model)
      end)
      |> Enum.reject(&is_nil/1)
    else
      # Fail-open by choice: a broken aqua tool reads as "no roles", not
      # as a refused turn — the soul still runs.
      _ -> []
    end
  end

  # --- Private helpers ---

  # The agent's own tree, when it names one — through the refocus
  # chokepoint (membership/archive checked), the same narrowing
  # `Aqua.Prompt` makes for the parent's base prompt. An unreachable owner
  # falls back to the focus read: an empty crew, never a refused turn.
  defp owner_read_ctx(ctx, owner) when is_binary(owner) do
    case Context.refocus(ctx, owner) do
      {:ok, read_ctx} -> read_ctx
      {:error, _} -> ctx
    end
  end

  defp owner_read_ctx(ctx, _), do: ctx

  # `ctx` here is the OWNER read context — the guide comes from the tree
  # the crew lives in; `listing` was resolved by the caller in the working
  # estate.
  defp build_role(ctx, listing, name, fallback_catalyst, fallback_model) do
    with {:ok, guide} <- call_aqua(ctx, %{"action" => "get", "name" => name}) do
      content = guide["content"] || ""
      description = guide["description"] || ""
      title = guide["title"] || name
      tool_policy = guide["tool_policy"] || %{}
      raw_catalyst = guide["catalyst_ref"]
      raw_model = guide["model"]

      # Resolve per-role catalyst, falling back to orchestrator's
      {catalyst_ref, model} =
        resolve_role_model(listing, raw_catalyst, raw_model, fallback_catalyst, fallback_model)

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

  defp resolve_role_model(listing, catalyst_ref, model, fallback_catalyst, fallback_model) do
    if is_binary(catalyst_ref) and is_binary(model) and listing != [] do
      case find_matching_catalyst(listing, catalyst_ref) do
        {:ok, resolved} -> {resolved, model}
        _ -> {fallback_catalyst, fallback_model}
      end
    else
      {fallback_catalyst, fallback_model}
    end
  end

  @doc """
  For each orchestrator's catalyst: the installed release it resolves to and
  whether its consent is complete — `%{catalyst_ref => {:ready | :needs_key
  | :missing, resolved_ref}}`.

  A model with no key is the one thing that keeps a fresh athanor's AQUA
  silent, so both the Agents page and the chat's own empty state ask here.
  """
  @spec model_status(Context.t() | nil, [map()]) :: %{String.t() => {atom(), String.t()}}
  def model_status(nil, _agents), do: %{}

  def model_status(%Context{} = ctx, agents) when is_list(agents) do
    listing =
      case catalyst_listing(ctx) do
        {:ok, components} -> components
        _ -> []
      end

    agents
    |> Enum.filter(&(&1["type"] == "soul"))
    |> Enum.map(& &1["catalyst_ref"])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Map.new(fn ref -> {ref, catalyst_status(ctx, listing, ref)} end)
  end

  defp catalyst_status(ctx, listing, ref) do
    with {:ok, resolved} <- find_matching_catalyst(listing, ref),
         {:ok, plan} <-
           Aqua.MCPHelpers.call_tool("component", ctx, %{
             "action" => "setup_plan",
             "reference" => resolved
           }) do
      if plan[:ready] || plan["ready"], do: {:ready, resolved}, else: {:needs_key, resolved}
    else
      _ -> {:missing, ref}
    end
  end

  @doc false
  def resolve_catalyst(%Context{} = ctx, versionless_ref) when is_binary(versionless_ref) do
    with {:ok, components} <- catalyst_listing(ctx) do
      find_matching_catalyst(components, versionless_ref)
    end
  end

  def resolve_catalyst(_ctx, nil), do: {:error, :no_catalyst_ref}

  # One listing for a whole pass: sub-agent resolution and model_status
  # used to fetch the full catalyst listing once per agent.
  defp catalyst_listing(ctx) do
    result =
      Aqua.MCPHelpers.call_tool("component", ctx, %{
        "action" => "list",
        "type" => "catalyst"
      })

    case result do
      {:ok, listing} when is_map(listing) ->
        case stringify_deep(listing) do
          %{"components" => components} when is_list(components) -> {:ok, components}
          _ -> {:error, :catalyst_lookup_failed}
        end

      _ ->
        {:error, :catalyst_lookup_failed}
    end
  end

  defp find_matching_catalyst(components, versionless_ref) do
    prefix = versionless_ref <> ":"

    match =
      components
      |> Enum.filter(fn c -> String.starts_with?(c["reference"] || "", prefix) end)
      # Semver precedence, not lexicographic max — "10.0.0" outranks "9.0.0".
      |> Compendium.Semver.sort_desc_by(fn c -> c["version"] || "0" end)
      |> List.first()

    case match do
      nil -> {:error, :catalyst_not_found}
      c -> {:ok, c["reference"]}
    end
  end

  @doc """
  Call the `aqua` tool and normalize its result to string keys.

  Every aqua call goes through here so guide maps arrive with ONE key
  spelling: in-process results are atom-keyed, wire round-trips
  string-keyed, and consumers must not carry `m[:k] || m["k"]` pairs. The
  console's agents page had a byte-identical private copy of this.
  """
  @spec call_aqua(Sanctum.Context.t(), map()) :: {:ok, term()} | {:error, term()}
  def call_aqua(ctx, args) do
    case Aqua.MCPHelpers.call_tool("aqua", ctx, args) do
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
  via the aqua tool, plus a runtime-context block (date, key paths)
  appended after a separator.

  Falls back to a generic prompt if the aqua lookup fails — keeps the
  agent usable while AQUA configuration is still being set up.

  The AUTHORED prompt only. What a turn is finally told — the runtime
  section, the approval prelude, whose estate it is working in — is
  `Aqua.Prompt.compose/2`'s, so exactly one place decides what the model is
  claimed to be able to do.
  """
  @spec base_prompt(Context.t(), String.t()) :: String.t()
  def base_prompt(%Context{} = ctx, orchestrator_name \\ "aqua") do
    fetch_base_prompt(ctx, orchestrator_name)
  end

  defp fetch_base_prompt(ctx, orchestrator_name) do
    case orchestrator_config(ctx, orchestrator_name) do
      {:ok, %{content: content}} ->
        content

      _ ->
        # Fail-open by design — an agent without instructions still runs —
        # but never silently: the substitution is an operator-visible fact.
        Logger.error(
          "[Aqua.AgentConfig] orchestrator #{inspect(orchestrator_name)} has no readable " <>
            "instructions — running on the generic fallback prompt"
        )

        "You are an agent inside CYFR, a secure personal foundry that forges brilliance into reality."
    end
  end
end
