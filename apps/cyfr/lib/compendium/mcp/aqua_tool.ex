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

  require Logger

  alias Compendium.AquaAgent
  alias Compendium.AquaPath
  alias Sanctum.Context

  # Repo root — used for compile-time doc embedding. Resolved by walking up
  # from this file until a mix.exs with a component-guide.md beside it is
  # found: the old marker was the generically-named guide alone, so a
  # same-named file anywhere above the checkout silently redirected the
  # embed — and a missing guide walked to `/` and failed as an :enoent on
  # /component-guide.md, a path naming nothing about the cause. A tree
  # without the marker fails the COMPILE with the reason spelled out
  # (`Compendium.WITSource` sets the precedent).
  # arca:bypass-ok=C — compile-time repo-root discovery.
  project_root_walk =
    Enum.reduce_while(1..10, Path.expand(__DIR__), fn _, dir ->
      if File.exists?(Path.join(dir, "mix.exs")) and
           File.exists?(Path.join(dir, "component-guide.md")) do
        {:halt, {:found, dir}}
      else
        {:cont, Path.expand(Path.join(dir, ".."))}
      end
    end)

  @project_root (case project_root_walk do
                   {:found, dir} ->
                     dir

                   _walked_off ->
                     raise "Compendium.MCP.AquaTool: no repo root with " <>
                             "component-guide.md found above #{Path.expand(__DIR__)} — " <>
                             "are the guide files present in the build context?"
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
        "Manage the AQUA agent system — orchestrators, sub-agents, prompts, scrolls, and documentation guides. Use 'list' to discover agents and guides, 'get' to retrieve prompts/docs, 'create'/'update'/'delete' to manage agents (pass type=orchestrator|sub-agent on create; docs are read-only), 'status' to see which files are shipped/modified/own, 'skill_list'/'skill_get' to read the estate's scrolls (procedures kept as Agent Skills under aqua/skills/<name>/SKILL.md), 'skill_create'/'skill_update' to write one, 'skill_delete' to remove one the estate made, or 'reset' to revert edited copies of shipped files (member-created agents and scrolls are kept unless all=true).",
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
          # A scroll is a procedure the estate learns. Writing one is a
          # member's act at the door and a card from a chain — the soul's
          # policy holds both writes at `ask`, so an agent proposes a
          # scroll and a person clicks. Deleting stays a member's act
          # alone: never proposable, never standing.
          "skill_create" => %{
            kind: :write,
            planes: [:external, :in_chain],
            permission: :component_manage
          },
          "skill_update" => %{
            kind: :write,
            planes: [:external, :in_chain],
            permission: :component_manage
          },
          "skill_delete" => %{
            kind: :destructive,
            planes: [:external],
            permission: :component_manage
          },
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
              "skill_get",
              "skill_create",
              "skill_update",
              "skill_delete"
            ],
            "description" =>
              "Action: list/get agents and guides, create/update/delete to manage agents (for create, pass type=orchestrator|sub-agent to choose the agent kind; docs are read-only), status for per-file provenance (bundled/bundled_modified/user), skill_list/skill_get to read scrolls, skill_create/skill_update to write one (name, description, content), skill_delete to remove one the estate made, or reset to revert edited copies of shipped files (member-created agents and scrolls are kept unless all=true)."
          },
          "name" => %{
            "type" => "string",
            "description" =>
              "Agent, guide, or scroll name (for get/update/delete and the skill_* actions)"
          },
          "type" => %{
            "type" => "string",
            "enum" => ["orchestrator", "sub-agent"],
            "description" => "Filter by type (for list action)"
          },
          "detail" => %{
            "type" => "boolean",
            "description" =>
              "For list: include each agent's full fields (model, tool_policy, " <>
                "catalyst_ref, content) — one call instead of a get per agent"
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
            "description" =>
              "Agent description shown to LLM (create/update), or the one line a scroll's index shows (skill_create/skill_update)"
          },
          "content" => %{
            "type" => "string",
            "description" =>
              "Prompt content in markdown (create/update), or the scroll's body (skill_create/skill_update)"
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
    ensure_bundle(ctx)
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
          # `AquaAgent.list/1` already read every file — the detail flag
          # only widens the projection. Without it the console fetched the
          # summary and then re-read each agent with a get, an N+1 the
          # server paid twice for data it was already holding.
          detail? = args["detail"] == true

          agents
          |> Enum.reject(& &1.disabled)
          |> Enum.map(fn agent ->
            base = %{
              name: agent.name,
              title: agent.title,
              type: type_name(agent.role),
              description: agent.description
            }

            base = if agent.parent, do: Map.put(base, :parent, agent.parent), else: base

            if detail? do
              Map.merge(base, %{
                model: agent.model,
                catalyst_ref: agent.catalyst_ref,
                tool_policy: agent.tool_policy,
                content: agent.prompt
              })
            else
              base
            end
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
    ensure_bundle(ctx)

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
        {:error, {:not_found, "Agent or guide", name}}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        passthrough_or_unavailable(reason, "aqua.get #{name}")
    end
  end

  def handle(_ctx, %{"action" => "get"}) do
    {:error, {:invalid_argument, "Missing required argument: name"}}
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
        other -> {:error, {:invalid_argument, "Unsupported aqua create type: #{inspect(other)}"}}
      end
    end
  end

  def handle(_ctx, %{"action" => "create"}) do
    {:error, {:invalid_argument, "Missing required argument: name"}}
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
      {:error, :not_found} ->
        {:error, {:not_found, "Agent", name}}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        passthrough_or_unavailable(reason, "aqua.update #{name}")
    end
  end

  def handle(_ctx, %{"action" => "update"}) do
    {:error, {:invalid_argument, "Missing required argument: name"}}
  end

  # --- delete ---
  # A shipped, unedited agent cannot be deleted (the athanor does not own
  # it) — disabling is the roster-removal verb. Deleting an EDITED copy of
  # a shipped agent reverts it to shipped; deleting a member-created agent
  # deletes it outright.

  def handle(%Context{} = ctx, %{"action" => "delete", "name" => name}) do
    # One call: the overlay's drop verb owns the whole disposition — the
    # bundled refusal, the not-found, and what the delete reveals — so
    # this adapter only puts words on its answers (and the old
    # status-then-drop pair's race window is gone with the second probe).
    with :ok <- validate_name(name) do
      case Arca.Overlay.drop_unit(ctx, AquaPath.agent_file(name)) do
        {:ok, :revealed_shipped} ->
          {:ok, %{deleted: name, restored: "shipped"}}

        {:ok, :deleted} ->
          {:ok, %{deleted: name}}

        {:error, :bundled} ->
          {:error,
           {:invalid_argument,
            "Agent '#{name}' ships with the server and cannot be deleted — " <>
              "disable it instead (update name=#{name} disabled=true)"}}

        {:error, :not_found} ->
          {:error, {:not_found, "Agent", name}}

        {:error, reason} ->
          Logger.error("[AquaTool] aqua.delete #{name} failed: #{inspect(reason)}")
          {:error, {:unavailable, "Storage"}}
      end
    end
  end

  def handle(_ctx, %{"action" => "delete"}) do
    {:error, {:invalid_argument, "Missing required argument: name"}}
  end

  # --- reset ---

  def handle(%Context{} = ctx, %{"action" => "reset"} = args) do
    case Compendium.AquaTemplate.reset(ctx, all: args["all"] == true) do
      {:ok, %{reverted: reverted, kept: kept}} ->
        files = Enum.map(Compendium.AquaTemplate.files(), &Enum.join(&1, "/"))
        {:ok, %{reset: true, reverted: reverted, kept: kept, files: files}}

      {:error, reason} ->
        Logger.error("[AquaTool] aqua.reset failed: #{inspect(reason)}")
        {:error, {:unavailable, "Storage"}}
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
        Logger.error("[AquaTool] aqua.status failed: #{inspect(reason)}")
        {:error, {:unavailable, "Storage"}}
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
        {:error, {:not_found, "Scroll", name}}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        passthrough_or_unavailable(reason, "aqua.skill_get #{name}")
    end
  end

  def handle(_ctx, %{"action" => "skill_get"}) do
    {:error, {:invalid_argument, "Missing required argument: name"}}
  end

  # A scroll is a dir unit with `SKILL.md` as its sentinel. Creating one
  # lands the manifest through the overlay's unit commit — refuse-or-
  # replace, sentinel last, rollback on failure — so a half-written scroll
  # never reads as one. The name is taken if the union holds it, shipped
  # or the estate's own.
  def handle(%Context{} = ctx, %{"action" => "skill_create", "name" => name} = args) do
    with :ok <- validate_name(name),
         :ok <- refute_skill_taken(ctx, name),
         {:ok, manifest} <- skill_manifest_bytes(name, args["description"], args["content"]) do
      case Arca.Overlay.commit_unit(
             ctx,
             AquaPath.skill_dir(name),
             {:files, [{[AquaPath.skill_manifest_name()], manifest}]},
             cap: {:checked, byte_size(manifest)}
           ) do
        {:ok, _written} ->
          {:ok, %{created: name}}

        {:error, {:limit_reached, _, _} = reason} ->
          {:error, reason}

        {:error, reason} ->
          Logger.error("[AquaTool] aqua.skill_create #{name} failed: #{inspect(reason)}")
          {:error, {:unavailable, "Storage"}}
      end
    end
  end

  def handle(_ctx, %{"action" => "skill_create"}) do
    {:error, {:invalid_argument, "Missing required argument: name"}}
  end

  # Updating rewrites the manifest alone. A plain put inside a shipped
  # scroll materializes the whole unit first (the overlay's copy-on-write),
  # so the scroll's other files come along; a unit commit here would have
  # replaced the unit whole and dropped them.
  def handle(%Context{} = ctx, %{"action" => "skill_update", "name" => name} = args) do
    with :ok <- validate_name(name),
         {:ok, meta, body} <- read_skill_manifest(ctx, name),
         {:ok, manifest} <-
           skill_manifest_bytes(
             name,
             Map.get(args, "description", meta["description"]),
             Map.get(args, "content", body)
           ),
         :ok <- Arca.put(ctx, AquaPath.skill_manifest(name), manifest) do
      {:ok, %{updated: name}}
    else
      {:error, :not_found} ->
        {:error, {:not_found, "Scroll", name}}

      {:error, {:invalid_argument, _} = refusal} ->
        {:error, refusal}

      {:error, {:limit_reached, _, _} = reason} ->
        {:error, reason}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        passthrough_or_unavailable(reason, "aqua.skill_update #{name}")
    end
  end

  def handle(_ctx, %{"action" => "skill_update"}) do
    {:error, {:invalid_argument, "Missing required argument: name"}}
  end

  # Same disposition as an agent: a shipped, unedited scroll cannot be
  # deleted; an edited copy reverts to shipped; the estate's own goes.
  def handle(%Context{} = ctx, %{"action" => "skill_delete", "name" => name}) do
    with :ok <- validate_name(name) do
      case Arca.Overlay.drop_unit(ctx, AquaPath.skill_dir(name)) do
        {:ok, :revealed_shipped} ->
          {:ok, %{deleted: name, restored: "shipped"}}

        {:ok, :deleted} ->
          {:ok, %{deleted: name}}

        {:error, :bundled} ->
          {:error,
           {:invalid_argument,
            "Scroll '#{name}' ships with the server and cannot be deleted — edit it, or reset"}}

        {:error, :not_found} ->
          {:error, {:not_found, "Scroll", name}}

        {:error, reason} ->
          Logger.error("[AquaTool] aqua.skill_delete #{name} failed: #{inspect(reason)}")
          {:error, {:unavailable, "Storage"}}
      end
    end
  end

  def handle(_ctx, %{"action" => "skill_delete"}) do
    {:error, {:invalid_argument, "Missing required argument: name"}}
  end

  # The terminal clause answers both shapes the dispatcher already
  # distinguishes: no `action` at all, and one this tool does not know.
  def handle(_ctx, args) do
    case args do
      %{"action" => action} -> {:error, {:unknown_action, "aqua.#{action}"}}
      _ -> {:error, :action_missing}
    end
  end

  # --- helpers ---

  # A refusal the `with` head already typed is the caller's answer; anything
  # else reaching an else arm is a storage term — logged, never reflected.
  defp passthrough_or_unavailable(reason, where) do
    if Emissary.MCP.ToolError.reason?(reason) do
      {:error, reason}
    else
      Logger.error("[AquaTool] #{where} failed: #{inspect(reason)}")
      {:error, {:unavailable, "Storage"}}
    end
  end

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

      # An agent is a file unit: the one atomic put IS the unit commit —
      # no sentinel, no rollback needed, the overlay's file CoW applies.
      case Arca.put(ctx, AquaPath.agent_file(name), AquaAgent.serialize(agent)) do
        :ok ->
          base = %{created: name, type: type_name(role)}
          {:ok, if(parent, do: Map.put(base, :parent, parent), else: base)}

        {:error, reason} ->
          Logger.error("[AquaTool] aqua.create #{name} failed: #{inspect(reason)}")
          {:error, {:unavailable, "Storage"}}
      end
    end
  end

  defp checked_parent(_ctx, _args, :orchestrator), do: {:ok, nil}

  defp checked_parent(ctx, args, :sub_agent) do
    case args["parent"] do
      parent when is_binary(parent) and parent != "" ->
        case AquaAgent.get(ctx, parent) do
          {:ok, %{role: :orchestrator}} -> {:ok, parent}
          {:ok, _} -> {:error, {:invalid_argument, "'#{parent}' is not an orchestrator"}}
          {:error, _} -> {:error, {:not_found, "Parent orchestrator", parent}}
        end

      _ ->
        {:error,
         {:invalid_argument, "Missing required argument: parent (required for type=sub-agent)"}}
    end
  end

  # The union answers for shipped and member-created agents alike — a name
  # either kind holds is taken.
  defp refute_name_taken(ctx, name) do
    if Arca.exists?(ctx, AquaPath.agent_file(name)),
      do: {:error, {:invalid_argument, "Agent '#{name}' already exists"}},
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

  defp refute_skill_taken(ctx, name) do
    if Arca.exists?(ctx, AquaPath.skill_manifest(name)),
      do: {:error, {:invalid_argument, "Scroll '#{name}' already exists"}},
      else: :ok
  end

  # The Agent Skills manifest: frontmatter `name` (the directory's) and a
  # one-line `description` (what the index shows), then the body. Both
  # are required — a scroll nobody can find by its line is not a scroll.
  # Values are JSON-encoded, the one YAML scalar spelling that survives
  # any description.
  defp skill_manifest_bytes(name, description, content) do
    description = if is_binary(description), do: String.trim(description), else: ""
    content = if is_binary(content), do: String.trim(content), else: ""

    cond do
      description == "" ->
        {:error, {:invalid_argument, "A scroll needs a one-line description"}}

      String.contains?(description, "\n") ->
        {:error, {:invalid_argument, "A scroll's description is one line"}}

      content == "" ->
        {:error, {:invalid_argument, "A scroll needs content"}}

      true ->
        {:ok,
         IO.iodata_to_binary([
           "---\n",
           "name: ",
           Jason.encode!(name),
           "\n",
           "description: ",
           Jason.encode!(description),
           "\n",
           "---\n\n",
           content,
           "\n"
         ])}
    end
  end

  # First need. A group estate is minted as a row and filled the first time
  # something actually reads its bundle, so clicking a person's name opens
  # a chat instead of waiting on a registry round trip that can fail.
  #
  # This tool is where every agent read lands — the roster, one agent's
  # detail, and therefore a turn, which resolves its orchestrator through
  # here before it runs. Hooking it once covers all three, and keeps the
  # reach inside the namespace that already reads the bundle rather than
  # spreading a tenancy call into the harness.
  defp ensure_bundle(%Context{} = ctx), do: Sanctum.Provisioning.ensure_provisioned(ctx)

  defp validate_name(name) do
    if AquaPath.valid_name?(name),
      do: :ok,
      else:
        {:error,
         {:invalid_argument, "Invalid name #{inspect(name)} — use letters, digits, '_' and '-'"}}
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
           {:invalid_argument,
            "Invalid tool_policy value #{inspect(value)} for #{inspect(key)} — use \"ask\" or \"auto\""}}

        not valid_policy_key?(key) ->
          {:error,
           {:invalid_argument,
            "Invalid tool_policy key #{inspect(key)} — use \"tool.action\", \"tool.*\", or \"native_search\""}}

        true ->
          nil
      end
    end)
  end

  defp validate_tool_policy(_),
    do: {:error, {:invalid_argument, "tool_policy must be an object"}}

  defp valid_policy_key?("native_search"), do: true

  defp valid_policy_key?(key) when is_binary(key) do
    case String.split(key, ".") do
      [tool, action] when tool != "" and action != "" -> true
      _ -> false
    end
  end

  defp valid_policy_key?(_), do: false
end
