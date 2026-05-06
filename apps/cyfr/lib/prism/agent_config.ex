defmodule Prism.AgentConfig do
  @moduledoc """
  Builds agent configuration for formula input by querying the `guide` MCP tool.

  All prompt and metadata access goes through the guide tool, which reads from
  `aqua/agent.json` at runtime. This ensures a single canonical API for both
  internal and external harnesses.
  """

  alias Sanctum.Context

  @doc "List available top-level orchestrators."
  def list_orchestrators(%Context{} = ctx) do
    case call_guide(ctx, %{"action" => "list", "type" => "orchestrator"}) do
      {:ok, %{guides: guides}} when is_list(guides) ->
        Enum.map(guides, fn g ->
          %{name: g[:name] || g["name"], title: g[:title] || g["title"]}
        end)

      {:ok, %{"guides" => guides}} when is_list(guides) ->
        Enum.map(guides, fn g ->
          %{name: g["name"], title: g["title"]}
        end)

      _ ->
        []
    end
  end

  @doc """
  Load full config for an orchestrator (prompt content + resolved catalyst).

  Uses the guide tool to fetch prompt content and metadata. Resolves the
  versionless catalyst_ref to the latest installed version.
  """
  def orchestrator_config(%Context{} = ctx, agent_name \\ "aqua") do
    name = agent_name || "aqua"

    with {:ok, guide} <- call_guide(ctx, %{"action" => "get", "name" => name}),
         content when is_binary(content) <- guide[:content] || guide["content"],
         catalyst_ref_raw <- guide[:catalyst_ref] || guide["catalyst_ref"],
         {:ok, catalyst_ref} <- resolve_catalyst(ctx, catalyst_ref_raw) do
      {:ok,
       %{
         name: name,
         title: guide[:title] || guide["title"],
         content: content,
         catalyst_ref: catalyst_ref,
         model: guide[:model] || guide["model"]
       }}
    else
      nil -> {:error, :no_content}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Build sub-agent definitions for formula input.

  Fetches all sub-agents via the guide tool, resolves per-role catalyst/model
  (inheriting from the orchestrator when not set), and enforces the
  native_search exclusivity constraint.
  """
  def sub_agent_definitions(%Context{} = ctx, agent_name, fallback_catalyst, fallback_model) do
    with {:ok, list_result} <- call_guide(ctx, %{"action" => "list", "type" => "sub-agent"}) do
      guides = extract_guides(list_result)

      # Filter to sub-agents belonging to this orchestrator
      parent_agents =
        guides
        |> Enum.filter(fn g ->
          parent = g[:parent] || g["parent"]
          parent == agent_name
        end)

      parent_agents
      |> Enum.map(fn g ->
        name = g[:name] || g["name"]
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
      content = guide[:content] || guide["content"] || ""
      description = guide[:description] || guide["description"] || ""
      title = guide[:title] || guide["title"] || name
      raw_visible = guide[:visible_tools] || guide["visible_tools"]
      raw_catalyst = guide[:catalyst_ref] || guide["catalyst_ref"]
      raw_model = guide[:model] || guide["model"]

      # Resolve per-role catalyst, falling back to orchestrator's
      {catalyst_ref, model} =
        resolve_role_model(ctx, raw_catalyst, raw_model, fallback_catalyst, fallback_model)

      # Enforce native_search exclusivity: if present, strip all other tools
      visible_tools =
        case raw_visible do
          tools when is_list(tools) ->
            if "native_search" in tools, do: ["native_search"], else: tools

          _ ->
            nil
        end

      %{
        "name" => name,
        "title" => title,
        "description" => description,
        "prompt" => content,
        "visible_tools" => visible_tools,
        "catalyst_ref" => catalyst_ref,
        "model" => model
      }
    else
      _ -> nil
    end
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
    case Emissary.MCP.ToolRegistry.call("component", ctx, %{
           "action" => "list",
           "type" => "catalyst"
         }) do
      {:ok, %{components: components}} when is_list(components) ->
        find_matching_catalyst(components, versionless_ref)

      {:ok, %{"components" => components}} when is_list(components) ->
        find_matching_catalyst(components, versionless_ref)

      _ ->
        {:error, :catalyst_lookup_failed}
    end
  end

  def resolve_catalyst(_ctx, nil), do: {:error, :no_catalyst_ref}

  defp find_matching_catalyst(components, versionless_ref) do
    prefix = versionless_ref <> ":"

    match =
      components
      |> Enum.filter(fn c ->
        ref = c["reference"] || to_string(c[:reference] || "")
        String.starts_with?(ref, prefix)
      end)
      |> Enum.max_by(
        fn c -> c["version"] || c[:version] || "0" end,
        fn -> nil end
      )

    case match do
      nil -> {:error, :catalyst_not_found}
      c -> {:ok, c["reference"] || to_string(c[:reference])}
    end
  end

  defp call_guide(ctx, args) do
    Emissary.MCP.ToolRegistry.call("aqua", ctx, args)
  end

  defp extract_guides(%{guides: guides}) when is_list(guides), do: guides
  defp extract_guides(%{"guides" => guides}) when is_list(guides), do: guides
  defp extract_guides(_), do: []

  # ============================================================================
  # System prompt composition
  # ============================================================================

  @doc """
  Build the full system prompt for an orchestrator: base prompt fetched
  via the guide tool, plus a runtime-context block (date, edition, key
  paths) appended after a separator.

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
    edition = if Sanctum.Edition.arx?(), do: :arx, else: :core

    "Current date: #{date_str}, #{day_name}, #{time_str}\n" <>
      "Platform edition: #{edition}\n" <>
      "File paths: data/ for user storage, components/ for installed components"
  end
end
