# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.MCP.AquaTool do
  @moduledoc """
  AQUA tool handlers for the Compendium MCP provider — agent system
  (orchestrators, sub-agents, prompts), the skills tree, and documentation
  guides.

  Agent definitions are the athanor's own: one frontmatter-markdown file
  per agent under `aqua/agents/` (`Compendium.AquaAgent` is the format,
  the directory is the roster), served through the seed overlay — shipped
  agents read through until edited, edited ones shadow only themselves,
  and deleting an edited copy reverts it to shipped. Skills follow the
  open Agent Skills convention under `aqua/skills/<name>/SKILL.md`.
  """

  alias Compendium.AquaAgent
  alias Compendium.AquaPath
  alias Sanctum.Context

  # Repo root — used for compile-time doc embedding. Resolved by walking up from
  # this file until the guide files are found, rather than hard-coding the number
  # of parent hops (which silently breaks whenever this module is moved).
  # arca:bypass-ok=C — compile-time repo-root discovery.
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
  # arca:bypass-ok=C — compile-time embed; runtime never reads these files.
  @component_guide File.read!(Path.join(@project_root, "component-guide.md"))
  @tincture_guide File.read!(Path.join(@project_root, "tincture-guide.md"))
  @integration_guide File.read!(Path.join(@project_root, "integration-guide.md"))

  # Agent and skill names become path segments — refused at this boundary
  # with a typed error, where the adapter would raise. The grammar itself
  # is the path's: `Compendium.AquaPath.valid_name?/1`.

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Compendium.MCP assembles its roster from these.
  def definition do
    %{
      name: "aqua",
      title: "AQUA Agent System",
      description:
        "Manage the AQUA agent system — orchestrators, sub-agents, prompts, skills, and documentation guides. Use 'list' to discover agents and guides, 'get' to retrieve prompts/docs, 'create'/'update'/'delete' to manage agents (pass type=orchestrator|sub-agent on create; docs are read-only), 'status' to see which agents are shipped/modified/own, 'skill_list'/'skill_get' for the skills tree, or 'reset' to revert edited copies of shipped files (member-created agents and skills are kept unless all=true).",
      annotations: %{
        readOnlyHint: false,
        destructiveHint: true,
        actions: %{
          # Agent definitions are the athanor's own. Reading them is open
          # to any authenticated caller, a running chain included; editing
          # them — the roster, the prompts, the `tool_policy` that decides
          # what a chain may call — is a member's act from outside, never
          # something a chain can do to itself.
          "list" => %{kind: :read, planes: [:external, :in_chain]},
          "get" => %{kind: :read, planes: [:external, :in_chain]},
          "status" => %{kind: :read, planes: [:external, :in_chain]},
          "skill_list" => %{kind: :read, planes: [:external, :in_chain]},
          "skill_get" => %{kind: :read, planes: [:external, :in_chain]},
          "create" => %{kind: :write, planes: [:external], permission: :component_manage},
          "update" => %{kind: :write, planes: [:external], permission: :component_manage},
          "delete" => %{
            kind: :destructive,
            planes: [:external],
            permission: :component_manage
          },
          # Reverts edited copies of shipped units to shipped;
          # member-created agents and skills are KEPT unless all=true
          # deletes the whole upper layer (Compendium.AquaTemplate.reset/2).
          "reset" => %{
            kind: :destructive,
            planes: [:external],
            permission: :component_manage
          }
        }
      },
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => [
              "list",
              "get",
              "create",
              "update",
              "delete",
              "reset",
              "status",
              "skill_list",
              "skill_get"
            ],
            "description" =>
              "Action: list/get agents and guides, create/update/delete to manage agents (for create, pass type=orchestrator|sub-agent to choose the agent kind; docs are read-only), status for per-file provenance (bundled/bundled_modified/user), skill_list/skill_get for the skills tree, or reset to revert edited copies of shipped files (member-created agents and skills are kept unless all=true)."
          },
          "name" => %{
            "type" => "string",
            "description" => "Agent, guide, or skill name (for get/update/delete/skill_get)"
          },
          "type" => %{
            "type" => "string",
            "enum" => ["orchestrator", "sub-agent"],
            "description" => "Filter by type (for list action)"
          },
          "parent" => %{
            "type" => "string",
            "description" => "Parent orchestrator name (for create sub-agent action)"
          },
          "title" => %{
            "type" => "string",
            "description" => "Human-readable title (for create/update actions)"
          },
          "description" => %{
            "type" => "string",
            "description" => "Agent description shown to LLM (for create/update actions)"
          },
          "content" => %{
            "type" => "string",
            "description" => "Prompt content in markdown (for create/update actions)"
          },
          "tool_policy" => %{
            "type" => "object",
            "additionalProperties" => %{"type" => "string", "enum" => ["ask", "auto"]},
            "description" =>
              "Per-(tool,action) allowlist for this agent. Keys are 'tool.action' or 'tool.*' strings (a bare 'native_search' key grants the provider-native search tool); values are 'auto' (directly callable) or 'ask' (reachable only through user approval). A pair missing from the map is not callable at all. Each action's risk level is derived from its `kind` annotation (read/write/execute/destructive/external) — color/UI treatment uses the kind, not the policy mode. The policy is the athanor's: every member edits the same allowlist."
          },
          "catalyst_ref" => %{
            "type" => "string",
            "description" => "Versionless catalyst reference (for create/update actions)"
          },
          "model" => %{
            "type" => "string",
            "description" => "Model identifier (for create/update actions)"
          },
          "disabled" => %{
            "type" => "boolean",
            "description" =>
              "Take an agent out of the roster without deleting its file (for update; shipped agents cannot be deleted — disable them instead)"
          },
          "all" => %{
            "type" => "boolean",
            "description" =>
              "For reset: also DELETE member-created agents and skills, so the tree becomes exactly the shipped set (default false keeps them)"
          }
        },
        "required" => ["action"]
      }
    }
  end

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
      case AquaAgent.list(ctx) do
        {:ok, agents, _errors} ->
          agents
          |> Enum.reject(& &1.disabled)
          |> Enum.map(fn agent ->
            base = %{
              name: agent.name,
              title: agent.title,
              type: type_name(agent.role),
              description: agent.description
            }

            if agent.parent, do: Map.put(base, :parent, agent.parent), else: base
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
    with :ok <- validate_name(name),
         {:ok, agent} <- AquaAgent.get(ctx, name) do
      {:ok,
       %{
         name: agent.name,
         format: "markdown",
         content: agent.prompt,
         type: type_name(agent.role),
         parent: agent.parent,
         title: agent.title,
         description: agent.description,
         tool_policy: agent.tool_policy,
         catalyst_ref: agent.catalyst_ref,
         model: agent.model,
         disabled: agent.disabled
       }}
    else
      {:error, :not_found} ->
        {:error, "Unknown agent or guide: #{name}. Use aqua(list) to see available agents."}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Failed to read agent '#{name}': #{inspect(reason)}"}
    end
  end

  def handle(_ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: name"}
  end

  # --- create ---
  # Dispatches by the `type` arg (orchestrator | sub-agent). When `type` is
  # absent, infers from presence of `parent`: parent → sub-agent, no parent →
  # orchestrator.

  def handle(%Context{} = ctx, %{"action" => "create", "name" => name} = args) do
    with :ok <- validate_name(name),
         :ok <- validate_tool_policy(args["tool_policy"]),
         :ok <- refute_name_taken(ctx, name) do
      case inferred_aqua_create_type(args) do
        "sub-agent" -> create_agent(ctx, name, args, :sub_agent)
        "orchestrator" -> create_agent(ctx, name, args, :orchestrator)
        other -> {:error, "Unsupported aqua create type: #{inspect(other)}"}
      end
    end
  end

  def handle(_ctx, %{"action" => "create"}) do
    {:error, "Missing required argument: name"}
  end

  # --- update ---

  def handle(%Context{} = ctx, %{"action" => "update", "name" => name} = args) do
    with :ok <- validate_name(name),
         :ok <- validate_tool_policy(args["tool_policy"]),
         {:ok, agent} <- AquaAgent.get(ctx, name),
         updated = apply_updates(agent, args),
         :ok <- Arca.put(ctx, AquaPath.agent_file(name), AquaAgent.serialize(updated)) do
      {:ok, %{updated: name}}
    else
      {:error, :not_found} -> {:error, "Agent '#{name}' not found"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "Failed to update: #{inspect(reason)}"}
    end
  end

  def handle(_ctx, %{"action" => "update"}) do
    {:error, "Missing required argument: name"}
  end

  # --- delete ---
  # A shipped, unedited agent cannot be deleted (the athanor does not own
  # it) — disabling is the roster-removal verb. Deleting an EDITED copy of
  # a shipped agent reverts it to shipped; deleting a member-created agent
  # deletes it outright.

  def handle(%Context{} = ctx, %{"action" => "delete", "name" => name}) do
    with :ok <- validate_name(name) do
      file = AquaPath.agent_file(name)

      case Arca.Overlay.unit_status(ctx, file) do
        {:ok, :seed} ->
          {:error,
           "Agent '#{name}' ships with the server and cannot be deleted — " <>
             "disable it instead (update name=#{name} disabled=true)"}

        {:ok, status} when status in [:materialized, :own, :own_shadowing] ->
          case Arca.Overlay.drop_unit(ctx, file) do
            :ok ->
              # The status already says what the delete reveals: an edited
              # copy or the athanor's own work over a shipped counterpart
              # uncovers it; plain own work is simply gone.
              if status in [:materialized, :own_shadowing] do
                {:ok, %{deleted: name, restored: "shipped"}}
              else
                {:ok, %{deleted: name}}
              end

            {:error, reason} ->
              {:error, "Failed to delete: #{inspect(reason)}"}
          end

        {:ok, :absent} ->
          {:error, "Agent '#{name}' not found"}

        {:error, reason} ->
          {:error, "Failed to read agent status: #{inspect(reason)}"}
      end
    end
  end

  def handle(_ctx, %{"action" => "delete"}) do
    {:error, "Missing required argument: name"}
  end

  # --- reset ---

  def handle(%Context{} = ctx, %{"action" => "reset"} = args) do
    case Compendium.AquaTemplate.reset(ctx, all: args["all"] == true) do
      {:ok, %{reverted: reverted, kept: kept}} ->
        files = Enum.map(Compendium.AquaTemplate.files(), &Enum.join(&1, "/"))
        {:ok, %{reset: true, reverted: reverted, kept: kept, files: files}}

      {:error, reason} ->
        {:error, "Failed to reset: #{inspect(reason)}"}
    end
  end

  # --- status ---

  def handle(%Context{} = ctx, %{"action" => "status"}) do
    case Compendium.AquaTemplate.status(ctx) do
      {:ok, entries} ->
        files =
          for %{path: path, state: state} <- entries do
            %{path: path, state: Compendium.Provenance.label(state)}
          end

        {:ok, %{files: files, count: length(files)}}

      {:error, reason} ->
        {:error, "Failed to read status: #{inspect(reason)}"}
    end
  end

  # --- skills ---

  def handle(%Context{} = ctx, %{"action" => "skill_list"}) do
    skills =
      case Arca.list_typed(ctx, AquaPath.skills_root()) do
        {:ok, entries} ->
          for {name, :dir} <- entries,
              {:ok, meta, _body} <- [read_skill_manifest(ctx, name)] do
            %{
              name: name,
              title: meta["name"] || name,
              description: meta["description"] || ""
            }
          end

        {:error, _} ->
          []
      end

    result = %{skills: Enum.sort_by(skills, & &1.name), count: length(skills)}

    # An honest empty state: the machinery is live even when the install
    # ships no skills — a release adding seed/aqua/skills/ needs no code.
    result =
      if skills == [] do
        Map.put(
          result,
          :hint,
          "No skills installed. Create one at aqua/skills/<name>/SKILL.md " <>
            "(Agent Skills format: frontmatter name + description); skills a " <>
            "release ships appear here automatically."
        )
      else
        result
      end

    {:ok, result}
  end

  def handle(%Context{} = ctx, %{"action" => "skill_get", "name" => name}) do
    with :ok <- validate_name(name),
         {:ok, meta, body} <- read_skill_manifest(ctx, name) do
      resources =
        case Arca.list_recursive(ctx, AquaPath.skill_dir(name)) do
          {:ok, leaves} ->
            leaves
            |> Enum.map(&Enum.drop(&1, length(AquaPath.skill_dir(name))))
            |> Enum.reject(&(&1 == [AquaPath.skill_manifest_name()]))
            |> Enum.map(&Enum.join(&1, "/"))
            |> Enum.sort()

          _ ->
            []
        end

      {:ok,
       %{
         name: name,
         title: meta["name"] || name,
         description: meta["description"] || "",
         format: "markdown",
         content: body,
         resources: resources
       }}
    else
      {:error, :not_found} ->
        {:error, "Unknown skill: #{name}. Use aqua(skill_list) to see available skills."}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Failed to read skill '#{name}': #{inspect(reason)}"}
    end
  end

  def handle(_ctx, %{"action" => "skill_get"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(_ctx, _args) do
    {:error, Emissary.MCP.ToolProvider.invalid_action("aqua", action_enum())}
  end

  # --- helpers ---

  defp type_name(:orchestrator), do: "orchestrator"
  defp type_name(:sub_agent), do: "sub-agent"

  defp inferred_aqua_create_type(%{"type" => type}) when is_binary(type) and type != "", do: type

  defp inferred_aqua_create_type(%{"parent" => parent}) when is_binary(parent) and parent != "",
    do: "sub-agent"

  defp inferred_aqua_create_type(_args), do: "orchestrator"

  defp create_agent(ctx, name, args, role) do
    with {:ok, parent} <- checked_parent(ctx, args, role) do
      agent = %{
        name: name,
        title: Map.get(args, "title", name),
        description: Map.get(args, "description", ""),
        role: role,
        parent: parent,
        default: false,
        disabled: false,
        catalyst_ref: args["catalyst_ref"],
        model: args["model"],
        tool_policy: args["tool_policy"] || %{},
        prompt: Map.get(args, "content", "")
      }

      case Arca.put(ctx, AquaPath.agent_file(name), AquaAgent.serialize(agent)) do
        :ok ->
          base = %{created: name, type: type_name(role)}
          {:ok, if(parent, do: Map.put(base, :parent, parent), else: base)}

        {:error, reason} ->
          {:error, "Failed to create agent: #{inspect(reason)}"}
      end
    end
  end

  defp checked_parent(_ctx, _args, :orchestrator), do: {:ok, nil}

  defp checked_parent(ctx, args, :sub_agent) do
    case args["parent"] do
      parent when is_binary(parent) and parent != "" ->
        case AquaAgent.get(ctx, parent) do
          {:ok, %{role: :orchestrator}} -> {:ok, parent}
          {:ok, _} -> {:error, "'#{parent}' is not an orchestrator"}
          {:error, _} -> {:error, "Parent orchestrator '#{parent}' not found"}
        end

      _ ->
        {:error, "Missing required argument: parent (required for type=sub-agent)"}
    end
  end

  # The union answers for shipped and member-created agents alike — a name
  # either kind holds is taken.
  defp refute_name_taken(ctx, name) do
    if Arca.exists?(ctx, AquaPath.agent_file(name)),
      do: {:error, "Agent '#{name}' already exists"},
      else: :ok
  end

  # `nil` for an updatable field removes it (v2 semantics); an absent key
  # leaves it alone. `content` swaps the prompt body.
  defp apply_updates(agent, args) do
    agent
    |> maybe_update(args, "title", :title, agent.name)
    |> maybe_update(args, "description", :description, "")
    |> maybe_update(args, "tool_policy", :tool_policy, %{})
    |> maybe_update(args, "catalyst_ref", :catalyst_ref, nil)
    |> maybe_update(args, "model", :model, nil)
    |> maybe_update(args, "disabled", :disabled, false)
    |> then(fn a ->
      case args["content"] do
        content when is_binary(content) -> %{a | prompt: content}
        _ -> a
      end
    end)
  end

  defp maybe_update(agent, args, arg_key, field, empty) do
    if Map.has_key?(args, arg_key) do
      case Map.get(args, arg_key) do
        nil -> Map.put(agent, field, empty)
        value -> Map.put(agent, field, value)
      end
    else
      agent
    end
  end

  defp read_skill_manifest(ctx, name) do
    with {:ok, binary} <- Arca.get(ctx, AquaPath.skill_manifest(name)) do
      AquaAgent.parse_frontmatter(binary)
    end
  end

  defp validate_name(name) do
    if AquaPath.valid_name?(name),
      do: :ok,
      else: {:error, "Invalid name #{inspect(name)} — use letters, digits, '_' and '-'"}
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

  defp action_enum, do: get_in(definition(), [:input_schema, "properties", "action", "enum"])
end
