# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.MCP.AquaTool do
  @moduledoc """
  AQUA tool handlers for the Compendium MCP provider — agent system
  (orchestrators, sub-agents, prompts) and documentation guides.

  Extracted from `Compendium.MCP`; behaviour preserved exactly.
  """

  alias Sanctum.Context

  # Repo root — used for compile-time doc embedding. Resolved by walking up from
  # this file until the guide files are found, rather than hard-coding the number
  # of parent hops (which silently breaks whenever this module is moved).
  @project_root Enum.reduce_while(1..10, Path.expand(__DIR__), fn _, dir ->
                  if File.exists?(Path.join(dir, "component-guide.md")) do
                    {:halt, dir}
                  else
                    {:cont, Path.expand(Path.join(dir, ".."))}
                  end
                end)

  # Documentation guides (arca:bypass-ok=C — compile-time embed; runtime never reads).
  @external_resource Path.join(@project_root, "component-guide.md")
  @external_resource Path.join(@project_root, "tincture-guide.md")
  @external_resource Path.join(@project_root, "integration-guide.md")
  @component_guide File.read!(Path.join(@project_root, "component-guide.md"))
  @tincture_guide File.read!(Path.join(@project_root, "tincture-guide.md"))
  @integration_guide File.read!(Path.join(@project_root, "integration-guide.md"))

  # --- list ---

  def handle(%Context{} = ctx, %{"action" => "list"} = args) do
    type_filter = Map.get(args, "type")

    doc_guides = [
      %{
        name: "component-guide",
        title: "Component Guide",
        type: "doc",
        description: "Building WASM components (catalysts, reagents, formulas) for CYFR"
      },
      %{
        name: "tincture-guide",
        title: "Tincture Guide",
        type: "doc",
        description:
          "Building tinctures (HTML/JS/CSS frontends) — SDK, sandbox constraints, manifest, examples"
      },
      %{
        name: "integration-guide",
        title: "Integration Guide",
        type: "doc",
        description: "How to use CYFR as your application backend"
      }
    ]

    agent_guides =
      case read_agent_manifest(ctx) do
        {:ok, %{"agents" => agents}} ->
          Enum.flat_map(agents, fn {name, config} ->
            orchestrator = %{
              name: name,
              title: config["title"] || name,
              type: "orchestrator",
              description: ""
            }

            sub_agents =
              (config["sub_agents"] || %{})
              |> Enum.map(fn {sa_name, sa_config} ->
                %{
                  name: sa_name,
                  title: sa_config["title"] || sa_name,
                  type: "sub-agent",
                  parent: name,
                  description: sa_config["description"] || ""
                }
              end)

            [orchestrator | sub_agents]
          end)

        _ ->
          []
      end

    all = doc_guides ++ agent_guides

    filtered =
      if type_filter,
        do: Enum.filter(all, &(&1.type == type_filter)),
        else: all

    {:ok, %{guides: filtered, count: length(filtered)}}
  end

  # --- get ---

  def handle(_ctx, %{"action" => "get", "name" => name})
      when name in ["component-guide", "tincture-guide", "integration-guide"] do
    content =
      case name do
        "component-guide" -> @component_guide
        "tincture-guide" -> @tincture_guide
        "integration-guide" -> @integration_guide
      end

    {:ok, %{name: name, format: "markdown", content: content, type: "doc"}}
  end

  def handle(%Context{} = ctx, %{"action" => "get", "name" => name}) do
    lookup_agent_guide(ctx, name)
  end

  def handle(_ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: name"}
  end

  # --- create ---
  # Dispatches by the `type` arg (orchestrator | sub-agent). When `type` is
  # absent, infers from presence of `parent`: parent → sub-agent, no parent →
  # orchestrator. Pass `type: "doc"` to create a markdown guide entry.

  def handle(%Context{} = ctx, %{"action" => "create", "name" => name} = args) do
    with :ok <- Context.require_permission_for_plane(ctx, :component_manage),
         :ok <- require_definition_authority(ctx),
         :ok <- validate_tool_policy(args["tool_policy"]) do
      type = inferred_aqua_create_type(args)

      case type do
        "sub-agent" -> create_aqua_sub_agent(ctx, name, args)
        "orchestrator" -> create_aqua_orchestrator(ctx, name, args)
        other -> {:error, "Unsupported aqua create type: #{inspect(other)}"}
      end
    end
  end

  def handle(_ctx, %{"action" => "create"}) do
    {:error, "Missing required argument: name"}
  end

  # --- update ---

  def handle(%Context{} = ctx, %{"action" => "update", "name" => name} = args) do
    with :ok <- Context.require_permission_for_plane(ctx, :component_manage),
         :ok <- require_definition_authority(ctx),
         :ok <- validate_tool_policy(args["tool_policy"]),
         {:ok, manifest} <- read_agent_manifest(ctx),
         {:ok, location} <- find_agent_in_manifest(manifest, name) do
      # Update manifest fields if provided
      updated_manifest =
        case location do
          {:orchestrator, _config} ->
            update_agent_fields(manifest, ["agents", name], args)

          {:sub_agent, parent, _config} ->
            update_agent_fields(manifest, ["agents", parent, "sub_agents", name], args)
        end

      # Update prompt content if provided
      prompt_result =
        case args["content"] do
          nil ->
            :ok

          content ->
            {_, config} =
              case location do
                {:orchestrator, c} -> {:orchestrator, c}
                {:sub_agent, _, c} -> {:sub_agent, c}
              end

            filename = config["prompt"] || "#{name}.md"
            Arca.put(ctx, ["aqua", filename], content)
        end

      with :ok <- write_agent_manifest(ctx, updated_manifest),
           :ok <- prompt_result do
        {:ok, %{updated: name}}
      else
        {:error, reason} -> {:error, "Failed to update: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def handle(_ctx, %{"action" => "update"}) do
    {:error, "Missing required argument: name"}
  end

  # --- delete ---

  def handle(%Context{} = ctx, %{"action" => "delete", "name" => name}) do
    with :ok <- Context.require_permission_for_plane(ctx, :component_manage),
         :ok <- require_definition_authority(ctx),
         {:ok, manifest} <- read_agent_manifest(ctx),
         {:ok, location} <- find_agent_in_manifest(manifest, name) do
      {updated, prompt_file} =
        case location do
          {:orchestrator, config} ->
            {update_in(manifest, ["agents"], &Map.delete(&1, name)), config["prompt"]}

          {:sub_agent, parent, config} ->
            {update_in(manifest, ["agents", parent, "sub_agents"], &Map.delete(&1, name)),
             config["prompt"]}
        end

      with :ok <- write_agent_manifest(ctx, updated) do
        # Best-effort delete of prompt file
        if prompt_file, do: Arca.delete(ctx, ["aqua", prompt_file])
        {:ok, %{deleted: name}}
      else
        {:error, reason} -> {:error, "Failed to delete: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def handle(_ctx, %{"action" => "delete"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(_ctx, _args) do
    {:error, "Invalid aqua action. Use: list, get, create, update, or delete"}
  end

  # Agent definitions are instance-global (`aqua/` bypasses tenant
  # segmentation), so on a deployment exposed to non-operator users a
  # tenant-scoped caller must not be able to rewrite every user's agents.
  # Single-user deployments (no :auth_provider) keep the permission check
  # as the only gate.
  defp require_definition_authority(%Context{} = ctx) do
    if Sanctum.auth_configured?() and ctx.scope != :platform do
      {:error,
       "Agent definitions are shared by every user of this deployment; " <>
         "changing them requires platform scope"}
    else
      :ok
    end
  end

  # --- aqua create helpers ---

  defp inferred_aqua_create_type(%{"type" => type}) when is_binary(type) and type != "", do: type

  defp inferred_aqua_create_type(%{"parent" => parent}) when is_binary(parent) and parent != "",
    do: "sub-agent"

  defp inferred_aqua_create_type(_args), do: "orchestrator"

  defp create_aqua_sub_agent(ctx, name, args) do
    parent = args["parent"]

    if is_nil(parent) or parent == "" do
      {:error, "Missing required argument: parent (required for type=sub-agent)"}
    else
      content = Map.get(args, "content", "")

      # The prompt file is keyed by name alone, so a sub-agent named after an
      # existing agent would overwrite that agent's system prompt — a way to
      # rewrite what another agent is, dressed up as creating a new one.
      with {:ok, manifest} <- read_agent_manifest(ctx),
           :ok <- refute_name_taken(manifest, parent, name),
           true <- Map.has_key?(manifest["agents"] || %{}, parent) do
        sa_config =
          %{
            "prompt" => "#{name}.md",
            "title" => Map.get(args, "title", name),
            "description" => Map.get(args, "description", "")
          }
          |> maybe_put("tool_policy", args["tool_policy"])
          |> maybe_put("catalyst_ref", args["catalyst_ref"])
          |> maybe_put("model", args["model"])

        updated = put_in(manifest, ["agents", parent, "sub_agents", name], sa_config)

        with :ok <- write_agent_manifest(ctx, updated),
             :ok <- Arca.put(ctx, ["aqua", "#{name}.md"], content) do
          {:ok, %{created: name, type: "sub-agent", parent: parent}}
        else
          {:error, reason} -> {:error, "Failed to create agent: #{inspect(reason)}"}
        end
      else
        false -> {:error, "Parent orchestrator '#{parent}' not found"}
        {:error, :name_taken} -> {:error, "Agent '#{name}' already exists"}
        {:error, reason} -> {:error, "Failed to read manifest: #{inspect(reason)}"}
      end
    end
  end

  # A name is taken by any orchestrator, or by a sub-agent under any parent —
  # every one of them stores its prompt at `aqua/<name>.md`.
  defp refute_name_taken(manifest, _parent, name) do
    agents = manifest["agents"] || %{}

    taken? =
      Map.has_key?(agents, name) or
        Enum.any?(agents, fn {_agent_name, config} ->
          config
          |> Kernel.||(%{})
          |> Map.get("sub_agents", %{})
          |> Map.has_key?(name)
        end)

    if taken?, do: {:error, :name_taken}, else: :ok
  end

  defp create_aqua_orchestrator(ctx, name, args) do
    content = Map.get(args, "content", "")

    with {:ok, manifest} <- read_agent_manifest(ctx) do
      if Map.has_key?(manifest["agents"] || %{}, name) do
        {:error, "Agent '#{name}' already exists"}
      else
        agent_config =
          %{
            "title" => Map.get(args, "title", name),
            "prompt" => "#{name}.md",
            "sub_agents" => %{}
          }
          |> maybe_put("catalyst_ref", args["catalyst_ref"])
          |> maybe_put("model", args["model"])
          |> maybe_put("tool_policy", args["tool_policy"])

        updated = put_in(manifest, ["agents", name], agent_config)

        with :ok <- write_agent_manifest(ctx, updated),
             :ok <- Arca.put(ctx, ["aqua", "#{name}.md"], content) do
          {:ok, %{created: name, type: "orchestrator"}}
        else
          {:error, reason} -> {:error, "Failed to create agent: #{inspect(reason)}"}
        end
      end
    end
  end

  # --- AQUA private helpers ---
  #
  # All AQUA reads/writes go through Arca (see Arca.Storage @global_prefixes
  # — `aqua` routes to `:cyfr, :aqua_path`, default `./aqua`). Tests still
  # override the location via `Application.put_env(:cyfr, :aqua_path, tmp)`
  # because the Local adapter resolves `aqua_path/0` from that env key.

  defp read_agent_manifest(%Context{} = ctx) do
    case Arca.get(ctx, ["aqua", "agent.json"]) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, manifest} -> {:ok, manifest}
          {:error, _} -> {:error, :manifest_not_found}
        end

      {:error, _} ->
        {:error, :manifest_not_found}
    end
  end

  defp write_agent_manifest(%Context{} = ctx, manifest) do
    case Jason.encode(manifest, pretty: true) do
      {:ok, json} -> Arca.put(ctx, ["aqua", "agent.json"], json <> "\n")
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_agent_prompt(%Context{} = ctx, filename) do
    Arca.get(ctx, ["aqua", filename])
  end

  defp lookup_agent_guide(%Context{} = ctx, name) do
    with {:ok, %{"agents" => agents}} <- read_agent_manifest(ctx) do
      case Map.get(agents, name) do
        %{"prompt" => filename} = config ->
          with {:ok, content} <- read_agent_prompt(ctx, filename) do
            {:ok,
             %{
               name: name,
               format: "markdown",
               content: content,
               type: "orchestrator",
               title: config["title"],
               catalyst_ref: config["catalyst_ref"],
               model: config["model"],
               tool_policy: config["tool_policy"],
               # Manifest policy merged with the caller's persisted per-user
               # grants (auto/deny) — the one policy harnesses feed into the
               # formula input. `tool_policy` above stays manifest-only for
               # the editors.
               effective_tool_policy:
                 Prism.AgentConfig.effective_tool_policy(ctx, name, config["tool_policy"] || %{})
             }}
          else
            _ -> {:error, "Failed to read prompt for orchestrator: #{name}"}
          end

        nil ->
          find_sub_agent_guide(ctx, agents, name)
      end
    else
      _ -> {:error, "Failed to read agent manifest"}
    end
  end

  defp find_sub_agent_guide(%Context{} = ctx, agents, name) do
    result =
      Enum.find_value(agents, fn {parent, config} ->
        case get_in(config, ["sub_agents", name]) do
          %{"prompt" => filename} = sa ->
            with {:ok, content} <- read_agent_prompt(ctx, filename) do
              {:ok,
               %{
                 name: name,
                 format: "markdown",
                 content: content,
                 type: "sub-agent",
                 parent: parent,
                 title: sa["title"],
                 description: sa["description"],
                 tool_policy: sa["tool_policy"],
                 effective_tool_policy:
                   Prism.AgentConfig.effective_tool_policy(ctx, name, sa["tool_policy"] || %{}),
                 catalyst_ref: sa["catalyst_ref"],
                 model: sa["model"]
               }}
            end

          _ ->
            nil
        end
      end)

    result || {:error, "Unknown agent or guide: #{name}. Use aqua(list) to see available agents."}
  end

  defp find_agent_in_manifest(manifest, name) do
    agents = manifest["agents"] || %{}

    case Map.get(agents, name) do
      %{} = config ->
        {:ok, {:orchestrator, config}}

      nil ->
        result =
          Enum.find_value(agents, fn {parent, config} ->
            case get_in(config, ["sub_agents", name]) do
              %{} = sa -> {:ok, {:sub_agent, parent, sa}}
              _ -> nil
            end
          end)

        result || {:error, "Agent '#{name}' not found"}
    end
  end

  # The policy vocabulary is exactly "ask" | "auto" and keys are
  # "tool.action", "tool.*", or a bare native-tool name ("native_search").
  # Anything else is rejected here so a schema-following caller can never
  # persist a value the formula would silently reinterpret (the runtime
  # treats every non-"auto" value as "ask").
  defp validate_tool_policy(nil), do: :ok

  defp validate_tool_policy(policy) when is_map(policy) do
    Enum.find_value(policy, :ok, fn {key, value} ->
      cond do
        value not in ["ask", "auto"] ->
          {:error,
           "Invalid tool_policy value #{inspect(value)} for #{inspect(key)} — use \"ask\" or \"auto\""}

        not valid_policy_key?(key) ->
          {:error,
           "Invalid tool_policy key #{inspect(key)} — use \"tool.action\", \"tool.*\", or \"native_search\""}

        true ->
          nil
      end
    end)
  end

  defp validate_tool_policy(_), do: {:error, "tool_policy must be an object"}

  defp valid_policy_key?("native_search"), do: true

  defp valid_policy_key?(key) when is_binary(key) do
    case String.split(key, ".") do
      [tool, action] when tool != "" and action != "" -> true
      _ -> false
    end
  end

  defp valid_policy_key?(_), do: false

  defp update_agent_fields(manifest, path, args) do
    updatable = ["title", "description", "tool_policy", "catalyst_ref", "model"]

    Enum.reduce(updatable, manifest, fn field, acc ->
      if Map.has_key?(args, field) do
        case Map.get(args, field) do
          nil ->
            # Explicitly set to nil → remove the field from manifest
            update_in(acc, path, fn config -> Map.delete(config, field) end)

          value ->
            put_in(acc, path ++ [field], value)
        end
      else
        acc
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
