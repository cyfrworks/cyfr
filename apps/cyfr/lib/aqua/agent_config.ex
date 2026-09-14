# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.AgentConfig do
  require Logger

  @moduledoc """
  The soul's and the roles' definitions, as a turn reads them.

  Reads are in-process: `roster/1` and `agent/2` read the athanor's
  `aqua/` tree through `Compendium.AquaAgent` — the same files the `aqua`
  tool serves, without the tool's round trip — and answer string-keyed
  maps in the tool's own projection, so a consumer reads one key spelling
  whether a definition came from here or over the wire. Every write, and
  every read made from outside the harness, still goes through the tool:
  `call_aqua/2` is the MCP door, kept for those.

  Each turn reads the roster and catalyst listing once, then builds role
  definitions from those results with `role_definitions/4`.
  """

  alias Compendium.AquaAgent
  alias Compendium.AquaPath
  alias Sanctum.Context

  # The authored tool_policy is edited on the AQUA page. Chat approvals are
  # stored separately in Aqua.ToolGrants and composed with it at use time.

  # What a storage fault reads as on the tape: the adapter's term is for
  # the log, the person gets the one sentence every storage-backed answer
  # gives.
  @unavailable {:unavailable, "The estate's AQUA tree"}

  @doc """
  The estate's agents, read once: the soul first, then the roles by name,
  disabled ones dropped — each as the string-keyed map the `aqua` tool's
  `list` with `detail` answers (`"name"`, `"title"`, `"description"`,
  `"type"`, `"content"`, `"tool_policy"`, `"catalyst_ref"`, `"model"`).

  Fails as it reads: a tree that cannot be listed is
  `{:error, {:unavailable, _}}`, never an empty roster a turn would
  quietly run without a crew. A single file that fails to parse is skipped
  and logged — one broken role must not take the soul down
  (`Compendium.AquaAgent.list/1`).

  The read is also where an estate gets its bundle on first need
  (`Sanctum.Provisioning.start_provisioning/1`): a group estate is minted
  as a bare row and filled the first time something reads it, and a turn
  roots an authority in that bundle right after this read. The `aqua`
  tool hooks its own reads the same way for callers outside the harness.
  """
  @spec roster(Context.t()) :: {:ok, [map()]} | {:error, {:unavailable, String.t()}}
  def roster(%Context{} = ctx) do
    Sanctum.Provisioning.start_provisioning(ctx)

    case AquaAgent.list(ctx) do
      {:ok, agents, errors} ->
        Enum.each(errors, fn {name, reason} ->
          Logger.warning(
            "[Aqua.AgentConfig] agent #{inspect(name)} skipped — it does not parse: " <>
              inspect(reason)
          )
        end)

        {:ok, agents |> Enum.reject(& &1.disabled) |> Enum.map(&project/1)}

      {:error, reason} ->
        Logger.error("[Aqua.AgentConfig] the aqua tree could not be listed: #{inspect(reason)}")
        {:error, @unavailable}
    end
  end

  @doc """
  One agent by name — the soul or a role — in the same projection as
  `roster/1`. `{:error, :not_found}` for a name the tree does not hold,
  and for one outside the name grammar: a name becomes a path segment, so
  it is checked here as the tool checks it at its door.
  """
  @spec agent(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def agent(%Context{} = ctx, name) when is_binary(name) do
    if AquaPath.valid_name?(name) do
      Sanctum.Provisioning.start_provisioning(ctx)

      with {:ok, agent} <- AquaAgent.get(ctx, name), do: {:ok, project(agent)}
    else
      {:error, :not_found}
    end
  end

  # The tool's `list detail: true` / `get` projection, string-keyed — the
  # one spelling this module's consumers read.
  defp project(agent) do
    %{
      "name" => agent.name,
      "title" => agent.title,
      "description" => agent.description,
      "type" => AquaAgent.type_of(agent),
      "content" => agent.prompt,
      "tool_policy" => agent.tool_policy,
      "catalyst_ref" => agent.catalyst_ref,
      "model" => agent.model,
      "disabled" => agent.disabled
    }
  end

  @doc """
  The role definitions a turn hands the formula — every role in `roster`
  (the tree the running agent lives in, read once by the caller), flat: a
  role has no roles of its own, and a soul spawns every role its estate
  keeps. An estate's soul reads its own tree and a person's agent theirs,
  so an estate's soul can never clone into a role that lives in someone's
  private tree.

  `listing` is the WORKING estate's catalyst listing
  (`catalyst_listing/1`): components belong to the estate the turn runs
  in, not to the agent's owner, so a role's own catalyst resolves against
  it and falls back to the parent's when it does not.

  `role_grants` is `%{role_name => rows}` (`Aqua.ToolGrants.for_agents/4`):
  a role's definition carries its EFFECTIVE policy — its authored one with
  the standing decisions made for that role and the kind ceiling applied
  (`Aqua.ToolGrants.resolve/2`), exactly as the soul's is composed — never
  the file as written. A "never" answered for the Builder holds when the
  soul clones into it.
  """
  @spec role_definitions([map()], [map()], String.t() | nil, String.t() | nil, map()) :: [map()]
  def role_definitions(roster, listing, fallback_catalyst, fallback_model, role_grants \\ %{})
      when is_list(roster) and is_list(listing) and is_map(role_grants) do
    role_type = AquaAgent.role_type()

    for %{"type" => ^role_type, "name" => name} = role <- roster do
      {catalyst_ref, model} =
        resolve_role_model(
          listing,
          role["catalyst_ref"],
          role["model"],
          fallback_catalyst,
          fallback_model
        )

      effective =
        Aqua.ToolGrants.resolve(role["tool_policy"] || %{}, Map.get(role_grants, name, []))

      %{
        "name" => name,
        "title" => role["title"] || name,
        "description" => role["description"] || "",
        "prompt" => role["content"] || "",
        "catalyst_ref" => catalyst_ref,
        "model" => model
      }
      |> put_formula_tool_surface(effective)
    end
  end

  @doc """
  Attach the formula's `tool_policy` allowlist
  (`{"tool.action" | "tool.*" => "ask" | "auto"}`) to an input/sub-agent map.

  The policy is the ONLY tool surface: it is always attached (an empty map
  when the agent carries none — the empty allowlist is the fail-closed
  default, never omission). The formula filters each tool's `action` enum to
  its directly-callable verbs (exactly those held at `"auto"`, whatever the
  kind), routes `"ask"` actions through the system-prompt approval prelude,
  and derives the provider-native search tool from a bare `"native_search"`
  policy key.
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
  silent, so both the AQUA page and the chat's own empty state ask here.
  """
  @spec model_status(Context.t() | nil, [map()]) :: %{String.t() => {atom(), String.t()}}
  def model_status(nil, _agents), do: %{}

  def model_status(%Context{} = ctx, agents) when is_list(agents) do
    listing =
      case catalyst_listing(ctx) do
        {:ok, components} -> components
        _ -> []
      end

    soul_type = AquaAgent.soul_type()

    agents
    |> Enum.filter(&(&1["type"] == soul_type))
    |> Enum.map(& &1["catalyst_ref"])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Map.new(fn ref -> {ref, catalyst_status(ctx, listing, ref)} end)
  end

  # A model is ready when its own profile binds a key AND the assistant's
  # consent selects that profile on its edge to the catalyst — the key
  # the assistant actually runs it with, resolved as a turn would resolve
  # it. A bound key the assistant's edge does not select is still a key
  # to connect.
  defp catalyst_status(ctx, listing, ref) do
    with {:ok, resolved} <- find_matching_catalyst(listing, ref),
         {:ok, plan} <-
           Aqua.Ops.call_tool("component", ctx, %{
             "action" => "setup_plan",
             "reference" => resolved
           }) do
      if (plan[:ready] || plan["ready"]) == true and lent_to_assistant?(ctx, ref),
        do: {:ready, resolved},
        else: {:needs_key, resolved}
    else
      _ -> {:missing, ref}
    end
  end

  defp lent_to_assistant?(ctx, catalyst_ref) do
    soul = Compendium.AgentSource.soul_ref()

    with {:ok, authority} <- Cyfr.Execution.authority_for(ctx, :default, soul),
         {:ok, edge} <-
           Cyfr.Authority.Blob.lookup_edge(authority.policy, soul, catalyst_ref, "") do
      Cyfr.Authority.Blob.bound_vault?(edge.vault)
    else
      _ -> false
    end
  end

  @doc """
  The installed release a versionless catalyst ref resolves to in
  `listing` — the newest by semver precedence, never lexicographic max
  ("10.0.0" outranks "9.0.0").
  """
  @spec resolve_catalyst([map()], String.t() | nil) ::
          {:ok, String.t()} | {:error, :catalyst_not_found | :no_catalyst_ref}
  def resolve_catalyst(listing, versionless_ref)
      when is_list(listing) and is_binary(versionless_ref),
      do: find_matching_catalyst(listing, versionless_ref)

  def resolve_catalyst(_listing, nil), do: {:error, :no_catalyst_ref}

  @doc """
  Returns the working athanor's installed catalysts through `component.list`.
  Read once per turn and pass to `resolve_catalyst/2` and `role_definitions/4`.

  Each row names its release in `component_ref`; that is the key the
  resolvers match on.
  """
  @spec catalyst_listing(Context.t()) :: {:ok, [map()]} | {:error, :catalyst_lookup_failed}
  def catalyst_listing(%Context{} = ctx) do
    result =
      Aqua.Ops.call_tool("component", ctx, %{
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
      |> Enum.filter(fn c -> String.starts_with?(c["component_ref"] || "", prefix) end)
      # Semver precedence, not lexicographic max — "10.0.0" outranks "9.0.0".
      |> Compendium.Semver.sort_desc_by(fn c -> c["version"] || "0" end)
      |> List.first()

    case match do
      nil -> {:error, :catalyst_not_found}
      c -> {:ok, c["component_ref"]}
    end
  end

  @doc """
  Call the `aqua` tool and normalize its result to string keys — the MCP
  door, for every write and for reads made from outside the harness (the
  console's AQUA page). A turn's own reads are in-process
  (`roster/1`, `agent/2`).

  Normalizes atom-keyed in-process results and string-keyed wire results
  to the same string-keyed representation.
  """
  @spec call_aqua(Sanctum.Context.t(), map()) :: {:ok, term()} | {:error, term()}
  def call_aqua(ctx, args) do
    case Aqua.Ops.call_tool("aqua", ctx, args) do
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

  # ============================================================================
  # System prompt composition
  # ============================================================================

  @generic_prompt "You are an agent inside CYFR, a secure personal foundry that forges brilliance into reality."

  @doc """
  The AUTHORED prompt of one agent, read from the tree `ctx` is focused
  on. What a turn is finally told — the runtime section, the approval
  prelude, whose estate it is working in — is `Aqua.Prompt.compose/2`'s,
  so exactly one place decides what the model is claimed to be able to
  do; a turn that already holds the roster hands the composer the prompt
  and never comes here.

  Falls back to a generic prompt if the agent has no readable instructions
  — an agent without instructions still runs — but never silently: the
  substitution is an operator-visible fact.
  """
  @spec base_prompt(Context.t(), String.t()) :: String.t()
  def base_prompt(%Context{} = ctx, name) when is_binary(name) do
    case agent(ctx, name) do
      {:ok, %{"content" => content}} when is_binary(content) ->
        content

      _ ->
        Logger.error(
          "[Aqua.AgentConfig] the soul or role #{inspect(name)} has no readable " <>
            "instructions — running on the generic fallback prompt"
        )

        @generic_prompt
    end
  end
end
