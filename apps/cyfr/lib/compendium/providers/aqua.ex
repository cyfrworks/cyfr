# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.Aqua do
  @moduledoc """
  Aqua tool handlers for the Compendium MCP provider — the soul and its
  crew, the scrolls, and the documentation guides.

  The soul and its crew are the athanor's own: one frontmatter-markdown
  file each — `aqua/aqua.md` and `aqua/crew/<name>.md`
  (`Compendium.AquaAgent` is the format, `Compendium.AquaPath` the
  layout) — served through the seed overlay: shipped files read through
  until edited, edited ones shadow only themselves, and deleting an
  edited copy reverts it to shipped. Skills follow the
  open Agent Skills convention under `aqua/skills/<name>/SKILL.md`.
  """

  require Logger

  alias Compendium.AquaAgent
  alias Compendium.AquaPath
  alias Sanctum.Context

  # Find the repository root by mix.exs and component-guide.md for compile-time
  # document embedding. Fail compilation if the root cannot be found.
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
                     raise "Compendium.Providers.Aqua: no repo root with " <>
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
  # handler they gate; Compendium.Provider assembles its roster from these.
  def definition do
    alias Prima.{Arg, Operation}
    # The soul and the crew are the athanor's own. Reading them is
    # open to any authenticated caller, a running chain included —
    # a turn resolves its agent through `get`, so the reads
    # carry no consent class and stay reachable from every surface
    # that can start one. Editing them — the crew, the prompts,
    # the `tools` a chain may call and each member's `mode` — is a
    # member's act from outside, never something a chain can do to
    # itself.
    # Every write is `consent: :interactive`: a person's own session
    # changes the soul, the crew and the scrolls, never a standing
    # credential — an API key, a `*` key included, is refused at the
    # registry's dispatch gate and does not see these actions in
    # `tools/list`.
    #
    # A scroll is a procedure the athanor learns. Writing one is a
    # member's act at the door, and a chain's under its member's mode:
    # in `auto` it writes, in `read-only` it is refused. In-chain the
    # interactive class keeps its surface half, so the write needs an
    # `:oidc`-rooted turn: a schedule- or key-started turn cannot write a
    # scroll, exactly like a note. Deleting stays a member's act alone.
    # Reset restores shipped units — one agent by name, else every
    # edited copy. With all=true it also deletes the crew members and
    # scrolls the athanor made.
    Operation.tool(
      [
        Operation.new(
          "aqua",
          "list",
          "List aqua",
          [
            Arg.new("detail", :boolean,
              description:
                "For list: include each agent's full fields (model, catalyst_ref, program, options, avoid, mode, tools, content, disabled) — one call instead of a get per agent"
            ),
            Arg.new("include_disabled", :boolean,
              description:
                "For list: include crew members set aside with disabled: true, which the roster otherwise leaves out"
            )
          ],
          kind: :read,
          sources: [],
          planes: [:external, :in_chain]
        ),
        Operation.new(
          "aqua",
          "get",
          "Get aqua",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Soul ('aqua'), crew member, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
            )
          ],
          kind: :read,
          sources: [],
          planes: [:external, :in_chain]
        ),
        Operation.new(
          "aqua",
          "create",
          "Create aqua",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Soul ('aqua'), crew member, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
            ),
            Arg.new("title", :string,
              description: "Human-readable title (for create/update actions)"
            ),
            Arg.new("description", :string,
              description:
                "What a crew member is good at, which the soul reads when it hands a job (create/update), or the one line a scroll's index shows (skill_create/skill_update)"
            ),
            Arg.new("catalyst_ref", :string,
              description: "Versionless catalyst reference (for create/update actions)"
            ),
            Arg.new("program", :string,
              description:
                "The id of the program row this agent's brain runs in, a driven program with a kept folder, in place of catalyst_ref (for create/update actions)"
            ),
            Arg.new("model", :string,
              description: "Model identifier (for create/update actions)"
            ),
            Arg.new("avoid", :string,
              description:
                "What the soul should never hand a crew member (create/update; crew members only)"
            ),
            Arg.new("mode", :string,
              enum: AquaAgent.modes(),
              description:
                "What of its offered tools the member runs: 'read-only' or 'auto' (the default)"
            ),
            Arg.new("options", {:map, Arg.new(nil, :json)},
              description:
                "The options this agent's brain is asked with on every request — names and values its describe declares (create/update)"
            ),
            Arg.new("content", :string,
              bulk: true,
              description:
                "Prompt content in markdown (create/update), or the scroll's body (skill_create/skill_update)"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive,
          permission: :component_manage
        ),
        Operation.new(
          "aqua",
          "update",
          "Update aqua",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Soul ('aqua'), crew member, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
            ),
            Arg.new("title", :string,
              nullable: true,
              description: "Human-readable title (for create/update actions)"
            ),
            Arg.new("description", :string,
              nullable: true,
              description:
                "What a crew member is good at, which the soul reads when it hands a job (create/update), or the one line a scroll's index shows (skill_create/skill_update)"
            ),
            Arg.new("catalyst_ref", :string,
              nullable: true,
              description: "Versionless catalyst reference (for create/update actions)"
            ),
            Arg.new("program", :string,
              nullable: true,
              description:
                "The id of the program row this agent's brain runs in, a driven program with a kept folder, in place of catalyst_ref (for create/update actions)"
            ),
            Arg.new("model", :string,
              nullable: true,
              description: "Model identifier (for create/update actions)"
            ),
            Arg.new("avoid", :string,
              nullable: true,
              description:
                "What the soul should never hand a crew member (create/update; crew members only)"
            ),
            Arg.new("options", {:map, Arg.new(nil, :json)},
              nullable: true,
              description:
                "The options this agent's brain is asked with on every request — names and values its describe declares (create/update)"
            ),
            Arg.new("options_patch", {:map, Arg.new(nil, :json, nullable: true)},
              description:
                "update only: the brain options to change, applied to the options as they are when the write lands — a value sets an option, null takes it off; options not named are kept, so two edits of different options at once keep both. Not with options."
            ),
            Arg.new("mode", :string,
              enum: AquaAgent.modes(),
              description:
                "What of its offered tools this member runs (create/update; the soul or a crew member): 'read-only' runs only reads, then answers, and every other call is refused; 'auto' runs every tool it is offered, deleting included. A file without it is auto."
            ),
            Arg.new("tools", {:array, Arg.new(nil, :string)},
              nullable: true,
              description:
                "The soul's tools, which every crew member is offered too (a crew member has none of its own): each one action, 'tool.action', 'native_search' (the provider's own search) or an outside server's 'server:tool', with no wildcard: every action of a tool is listed by name. A tool missing from the list is not callable at all; null offers nothing."
            ),
            Arg.new("tools_add", {:array, Arg.new(nil, :string)},
              description:
                "update only: tools to add to the soul's list as it is when the write lands, so two edits of different tools at once keep both. Not with tools."
            ),
            Arg.new("tools_remove", {:array, Arg.new(nil, :string)},
              description:
                "update only: tools to take off the soul's list as it is when the write lands. Not with tools."
            ),
            Arg.new("content", :string,
              bulk: true,
              description:
                "Prompt content in markdown (create/update), or the scroll's body (skill_create/skill_update)"
            ),
            Arg.new("disabled", :boolean,
              nullable: true,
              description:
                "Take a crew member out of the crew without deleting its file (for update; shipped members cannot be deleted — disable them instead)"
            ),
            Arg.new("expected_digest", :string,
              description:
                "update only: the content_digest that get answered for the prompt being edited. The update is refused as a conflict when the prompt has changed since, so one edit never writes over another."
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive,
          permission: :component_manage
        ),
        Operation.new(
          "aqua",
          "delete",
          "Delete aqua",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Soul ('aqua'), crew member, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
            )
          ],
          kind: :destructive,
          planes: [:external],
          consent: :interactive,
          permission: :component_manage
        ),
        Operation.new(
          "aqua",
          "reset",
          "Reset aqua",
          [
            Arg.new("name", :string,
              description:
                "Soul ('aqua'), crew member, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
            ),
            Arg.new("all", :boolean,
              description:
                "For reset: also DELETE the crew members and scrolls the athanor made, so the tree becomes exactly the shipped set (default false keeps them)"
            )
          ],
          kind: :destructive,
          planes: [:external],
          consent: :interactive,
          permission: :component_manage
        ),
        Operation.new("aqua", "status", "Status aqua", [],
          kind: :read,
          sources: [],
          planes: [:external, :in_chain]
        ),
        Operation.new("aqua", "skill_list", "Skill list aqua", [],
          kind: :read,
          sources: [],
          planes: [:external, :in_chain],
          recovery: :replay_safe
        ),
        Operation.new(
          "aqua",
          "skill_get",
          "Skill get aqua",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Soul ('aqua'), crew member, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
            )
          ],
          kind: :read,
          sources: [],
          planes: [:external, :in_chain],
          recovery: :replay_safe
        ),
        Operation.new(
          "aqua",
          "skill_create",
          "Skill create aqua",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Soul ('aqua'), crew member, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
            ),
            Arg.new("description", :string,
              required: true,
              description:
                "What a crew member is good at, which the soul reads when it hands a job (create/update), or the one line a scroll's index shows (skill_create/skill_update)"
            ),
            Arg.new("content", :string,
              required: true,
              bulk: true,
              description:
                "Prompt content in markdown (create/update), or the scroll's body (skill_create/skill_update)"
            )
          ],
          kind: :write,
          sources: [],
          planes: [:external, :in_chain],
          consent: :interactive,
          permission: :component_manage,
          standing: false
        ),
        Operation.new(
          "aqua",
          "skill_update",
          "Skill update aqua",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Soul ('aqua'), crew member, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
            ),
            Arg.new("description", :string,
              description:
                "What a crew member is good at, which the soul reads when it hands a job (create/update), or the one line a scroll's index shows (skill_create/skill_update)"
            ),
            Arg.new("content", :string,
              bulk: true,
              description:
                "Prompt content in markdown (create/update), or the scroll's body (skill_create/skill_update)"
            )
          ],
          kind: :write,
          sources: [],
          planes: [:external, :in_chain],
          consent: :interactive,
          permission: :component_manage,
          standing: false
        ),
        Operation.new(
          "aqua",
          "skill_delete",
          "Skill delete aqua",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Soul ('aqua'), crew member, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
            )
          ],
          kind: :destructive,
          planes: [:external],
          consent: :interactive,
          permission: :component_manage
        ),
        Operation.new(
          "aqua",
          "skill_reset",
          "Skill reset aqua",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Soul ('aqua'), crew member, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
            )
          ],
          kind: :destructive,
          planes: [:external],
          consent: :interactive,
          permission: :component_manage
        )
      ],
      description:
        "The athanor's Aqua: one soul (the assistant, reserved name 'aqua'), the crew it hands jobs to through crew.ask (each a brain with what it is good at and what to avoid, offered the soul's tools and running them in its own mode), the scrolls it has learned, and the documentation guides. Use 'list' to see the soul, crew and guides, 'get' to read one (the soul by name 'aqua'), 'create'/'update'/'delete' to manage crew members ('aqua' cannot be created or deleted — edit it, or reset), 'status' for per-file provenance, 'skill_list'/'skill_get' to read scrolls (Agent Skills under aqua/skills/<name>/SKILL.md), 'skill_create'/'skill_update' to write one, 'skill_delete' to remove one the athanor made, 'skill_reset' to restore an edited scroll to what ships, or 'reset' to restore edited copies of shipped files (one agent with name, else every one; crew members and scrolls the athanor made are kept unless all=true).",
      title: "Aqua Agent System"
    )
  end

  # --- list ---

  def handle(%Context{} = ctx, %{"action" => "list"} = args) do
    ensure_bundle(ctx)

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

    # A list the store could not give, or a soul it could not read, is
    # refused, a typed refusal as it came and any other answer as the
    # file's other reads refuse it (`passthrough_or_unavailable/2`):
    # answering the guides without the agents the store holds would read
    # as an athanor with no assistant. A crew member that could not be read
    # stays out of the crew.
    with {:ok, agents, errors} <- AquaAgent.list(ctx),
         :ok <- soul_read(errors) do
      # The detail flag widens the projection of the already-loaded agents.
      detail? = args["detail"] == true
      # Disabled crew members are out of the crew: the model's roster never
      # holds them. A page that puts them back asks for them by flag,
      # in the same read, rather than by a `get` per file.
      include_disabled? = args["include_disabled"] == true

      agent_guides =
        agents
        |> Enum.reject(&(&1.disabled and not include_disabled?))
        |> Enum.map(fn agent ->
          base = %{
            name: agent.name,
            title: agent.title,
            type: AquaAgent.type_of(agent),
            description: agent.description
          }

          if detail? do
            Map.merge(base, %{
              model: agent.model,
              catalyst_ref: agent.catalyst_ref,
              program: agent.program,
              options: agent.options,
              avoid: agent.avoid,
              mode: agent.mode,
              tools: agent.tools,
              content: agent.prompt,
              disabled: agent.disabled
            })
          else
            base
          end
        end)

      # The soul first, then the crew, then the guides.
      all = agent_guides ++ doc_guides

      {:ok, %{guides: all, count: length(all)}}
    else
      {:error, reason} -> passthrough_or_unavailable(reason, "aqua.list")
    end
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
         type: AquaAgent.type_of(agent),
         title: agent.title,
         description: agent.description,
         avoid: agent.avoid,
         mode: agent.mode,
         tools: agent.tools,
         catalyst_ref: agent.catalyst_ref,
         program: agent.program,
         model: agent.model,
         options: agent.options,
         disabled: agent.disabled,
         content_digest: content_digest(agent.prompt)
       }}
    else
      {:error, :not_found} ->
        {:error, {:not_found, "Soul, crew member or guide", name}}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        passthrough_or_unavailable(reason, "aqua.get #{name}")
    end
  end

  # --- create ---
  # A crew member. The soul is never created: its name is reserved, it
  # ships with the server, and `update` is how it changes.

  def handle(%Context{} = ctx, %{"action" => "create", "name" => name} = args) do
    with :ok <- validate_name(name),
         :ok <- refute_reserved(name),
         :ok <- no_crew_tools(name, args),
         :ok <- validate_mode(args["mode"]),
         :ok <- validate_options(args["options"]),
         :ok <- one_brain(%{catalyst_ref: args["catalyst_ref"], program: args["program"]}) do
      create_member(ctx, name, args)
    end
  end

  # --- update ---

  # One serialized read-modify-write, like a scroll's: two members
  # editing the same agent at once each see the other's bytes, never
  # overwrite them, because the write is made only while the file still
  # holds the bytes the edit was given. Two edits meet in two ways. A
  # tools edit arrives as `tools_add` and `tools_remove`, applied to the
  # soul's list as it is at the moment of the write, so two members
  # toggling different tools at once keep both; `tools` still replaces
  # the list for a caller that means to. A
  # prompt edit may carry `expected_digest` (the `content_digest` `get`
  # answered) and is refused as a conflict when the prompt has changed
  # since, rather than writing over the other member's words.
  def handle(%Context{} = ctx, %{"action" => "update", "name" => name} = args) do
    rewrite = fn bytes ->
      with {:ok, agent} <- AquaAgent.parse(name, bytes),
           :ok <- check_expected_digest(agent, args["expected_digest"]),
           agent = apply_updates(agent, args),
           :ok <- one_brain(agent) do
        tools = patched_tools(agent.tools, args["tools_add"], args["tools_remove"])
        options = patched_options(agent.options, args["options_patch"])
        {:ok, AquaAgent.serialize(%{agent | tools: tools, options: options})}
      end
    end

    with :ok <- validate_name(name),
         :ok <- no_crew_tools(name, args),
         :ok <- one_tools_argument(args),
         :ok <- validate_mode(args["mode"]),
         :ok <- validate_tools(args["tools"]),
         :ok <- validate_tools(args["tools_add"]),
         :ok <- validate_tools(args["tools_remove"]),
         :ok <- one_options_argument(args),
         :ok <- validate_options(args["options"]),
         :ok <- validate_options_patch(args["options_patch"]),
         :ok <-
           Arca.Overlay.update(Sanctum.Context.actor(ctx), AquaPath.agent_file(name), rewrite) do
      resync_index(ctx)
      {:ok, %{updated: name}}
    else
      {:error, :not_found} ->
        {:error, {:not_found, "Soul or crew member", name}}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        passthrough_or_unavailable(reason, "aqua.update #{name}")
    end
  end

  # --- delete ---
  # A shipped crew member, edited or not, cannot be deleted (a reset
  # restores it) — disabling is how it leaves the crew. An athanor-made
  # member deletes outright. The soul takes the same verb and refuses with its
  # own sentence.

  def handle(%Context{} = ctx, %{"action" => "delete", "name" => name}) do
    # The overlay's drop verb owns the whole disposition — the bundled
    # refusal, the not-found, the delete — so this adapter only puts
    # words on its answers.
    with :ok <- validate_name(name) do
      case Arca.Overlay.drop_unit(Sanctum.Context.actor(ctx), AquaPath.agent_file(name)) do
        {:ok, :deleted} ->
          resync_index(ctx)
          {:ok, %{deleted: name}}

        {:error, :bundled} ->
          {:error, {:invalid_argument, bundled_delete_message(name)}}

        {:error, :not_found} ->
          {:error, {:not_found, "Soul or crew member", name}}

        # This member's slot is not live: nothing was removed, and the
        # refusal reads as itself.
        {:error, :not_owner} = refused ->
          refused

        {:error, reason} ->
          Logger.error(
            "[Compendium.Providers.Aqua] aqua.delete #{name} failed: #{inspect(reason)}"
          )

          {:error, {:unavailable, "Storage"}}
      end
    end
  end

  # --- reset ---
  # With a name, one crew member's (or the soul's) edited copy is restored;
  # without, every edited copy of a shipped unit.

  def handle(%Context{} = ctx, %{"action" => "reset", "name" => name}) when is_binary(name) do
    with :ok <- validate_name(name) do
      restore_unit(ctx, AquaPath.agent_file(name), "Soul or crew member", name)
    end
  end

  def handle(%Context{} = ctx, %{"action" => "reset"} = args) do
    case Compendium.AquaTemplate.reset(ctx, all: args["all"] == true) do
      {:ok, %{reverted: reverted, kept: kept}} ->
        resync_index(ctx)
        files = Enum.map(Compendium.AquaTemplate.files(), &Enum.join(&1, "/"))
        {:ok, %{reset: true, reverted: reverted, kept: kept, files: files}}

      # A removal or a restore refused for this member's slot: the reset
      # stopped there, and the refusal reads as itself.
      {:error, :not_owner} = refused ->
        refused

      {:error, reason} ->
        Logger.error("[Compendium.Providers.Aqua] aqua.reset failed: #{inspect(reason)}")
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
        Logger.error("[Compendium.Providers.Aqua] aqua.status failed: #{inspect(reason)}")
        {:error, {:unavailable, "Storage"}}
    end
  end

  # --- skills ---

  # The index is `Compendium.AquaSkills`' — the same read the turn's
  # prompt makes in-process, so the tool and the prompt cannot list two
  # different sets of scrolls.
  def handle(%Context{} = ctx, %{"action" => "skill_list"}) do
    case Compendium.AquaSkills.index(ctx) do
      {:ok, []} ->
        # An honest empty state: the machinery is live even when the
        # install ships no skills — a release adding seed/aqua/skills/
        # needs no code.
        {:ok,
         %{
           skills: [],
           count: 0,
           hint:
             "No skills installed. Create one at aqua/skills/<name>/SKILL.md " <>
               "(Agent Skills format: frontmatter name + description); skills a " <>
               "release ships appear here automatically."
         }}

      {:ok, skills} ->
        {:ok, %{skills: skills, count: length(skills)}}

      {:error, reason} ->
        Logger.error("[Compendium.Providers.Aqua] aqua.skill_list failed: #{inspect(reason)}")
        {:error, {:unavailable, "Storage"}}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "skill_get", "name" => name}) do
    with :ok <- validate_name(name),
         {:ok, meta, body} <- Compendium.AquaSkills.read_manifest(ctx, name) do
      resources =
        case Arca.list_recursive(Sanctum.Context.actor(ctx), AquaPath.skill_dir(name)) do
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

  # A scroll is a dir unit with `SKILL.md` as its sentinel. Creating one
  # lands the manifest through the overlay's unit commit — sentinel last,
  # rollback on failure — so a half-written scroll never reads as one. The
  # name is taken if the union holds it, shipped or the athanor's own, and
  # the commit asks that while it holds the unit's draft (`if_absent:`),
  # so two creators of one name cannot both pass a probe and have the
  # second silently replace the first.
  def handle(%Context{} = ctx, %{"action" => "skill_create", "name" => name} = args) do
    with :ok <- validate_name(name),
         {:ok, manifest} <- skill_manifest_bytes(name, args["description"], args["content"]) do
      case Arca.Overlay.commit_unit(
             Sanctum.Context.actor(ctx),
             AquaPath.skill_dir(name),
             {:files, [{[AquaPath.skill_manifest_name()], manifest}]},
             cap: {:checked, byte_size(manifest)},
             if_absent: true
           ) do
        {:ok, _written} ->
          {:ok, %{created: name}}

        {:error, :exists} ->
          {:error, {:invalid_argument, "Scroll '#{name}' already exists"}}

        {:error, {:limit_reached, _, _} = reason} ->
          {:error, reason}

        {:error, reason} ->
          passthrough_or_unavailable(reason, "aqua.skill_create #{name}")
      end
    end
  end

  # Updating rewrites the manifest alone, as one serialized
  # read-modify-write: the fields the call leaves out are read from the
  # manifest as it is at the moment of the write, so two concurrent
  # updates cannot lose one.
  # The write inside is a plain put, so the scroll's other files stay; a
  # unit commit here would replace the unit whole and drop them.
  def handle(%Context{} = ctx, %{"action" => "skill_update", "name" => name} = args) do
    rewrite = fn current ->
      with {:ok, meta, body} <- AquaAgent.parse_frontmatter(current) do
        skill_manifest_bytes(
          name,
          Map.get(args, "description", meta["description"]),
          Map.get(args, "content", body)
        )
      end
    end

    with :ok <- validate_name(name),
         :ok <-
           Arca.Overlay.update(Sanctum.Context.actor(ctx), AquaPath.skill_manifest(name), rewrite) do
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

  # Same disposition as an agent: a shipped scroll is restored by a reset,
  # never deleted; the athanor's own goes.
  def handle(%Context{} = ctx, %{"action" => "skill_delete", "name" => name}) do
    with :ok <- validate_name(name) do
      case Arca.Overlay.drop_unit(Sanctum.Context.actor(ctx), AquaPath.skill_dir(name)) do
        {:ok, :deleted} ->
          {:ok, %{deleted: name}}

        {:error, :bundled} ->
          {:error,
           {:invalid_argument,
            "Scroll '#{name}' ships with the server and cannot be deleted — edit it, or reset"}}

        {:error, :not_found} ->
          {:error, {:not_found, "Scroll", name}}

        {:error, :not_owner} = refused ->
          refused

        {:error, reason} ->
          Logger.error(
            "[Compendium.Providers.Aqua] aqua.skill_delete #{name} failed: #{inspect(reason)}"
          )

          {:error, {:unavailable, "Storage"}}
      end
    end
  end

  # --- skill_reset ---

  def handle(%Context{} = ctx, %{"action" => "skill_reset", "name" => name}) do
    with :ok <- validate_name(name) do
      restore_unit(ctx, AquaPath.skill_dir(name), "Scroll", name)
    end
  end

  # --- helpers ---

  # A refusal the `with` head already typed is the caller's answer; anything
  # else reaching an else arm is a storage term — logged, never reflected.
  defp passthrough_or_unavailable(reason, where) do
    if Prima.Refusal.reason?(reason) do
      {:error, reason}
    else
      Logger.error("[Compendium.Providers.Aqua] #{where} failed: #{inspect(reason)}")
      {:error, {:unavailable, "Storage"}}
    end
  end

  defp refute_reserved(name) do
    if AquaPath.soul?(name),
      do:
        {:error,
         {:invalid_argument,
          "'#{name}' is the soul — it ships with the server and is edited with update, never created"}},
      else: :ok
  end

  defp bundled_delete_message(name) do
    if AquaPath.soul?(name),
      do: "The soul ships with the server and cannot be deleted — edit it, or reset",
      else:
        "Crew member '#{name}' ships with the server and cannot be deleted — " <>
          "disable it instead (update name=#{name} disabled=true)"
  end

  # One unit back to what ships; the athanor's own work refuses in words.
  defp restore_unit(ctx, unit, noun, name) do
    case Compendium.AquaTemplate.restore(ctx, unit) do
      :ok ->
        resync_index(ctx)
        {:ok, %{restored: name}}

      {:error, :not_a_copy} ->
        {:error,
         {:invalid_argument,
          "#{noun} '#{name}' is this athanor's own and has no shipped version to restore"}}

      {:error, :not_found} ->
        {:error, {:not_found, noun, name}}

      {:error, :not_owner} = refused ->
        refused

      {:error, reason} ->
        Logger.error(
          "[Compendium.Providers.Aqua] aqua restore #{name} failed: #{inspect(reason)}"
        )

        {:error, {:unavailable, "Storage"}}
    end
  end

  # The tree changed; the derived index follows it now, and the athanor's
  # consent caches with it. Never the write's failure: the write stamped
  # its unit, so an index that could not follow here is brought up to the
  # tree by its next read (`Compendium.ProjectionReconciler`).
  defp resync_index(ctx) do
    case Compendium.AgentIndex.sync(ctx) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Compendium.Providers.Aqua] agent index not synced: #{inspect(reason)}")
    end
  end

  defp create_member(ctx, name, args) do
    member = %{
      name: name,
      title: Map.get(args, "title", name),
      description: Map.get(args, "description", ""),
      avoid: Map.get(args, "avoid", ""),
      disabled: false,
      catalyst_ref: args["catalyst_ref"],
      program: args["program"],
      model: args["model"],
      options: args["options"] || %{},
      mode: args["mode"] || "auto",
      tools: [],
      prompt: Map.get(args, "content", "")
    }

    # A crew member is a file unit: the one atomic put IS the unit commit
    # — no sentinel, no rollback needed, the overlay's file CoW applies. It
    # goes through the commit for `if_absent:` alone: the union answers
    # for shipped and athanor-made members alike, and asking it while the
    # commit holds the unit's draft is what keeps two creators of one
    # name from both passing a probe.
    bytes = AquaAgent.serialize(member)

    case Arca.Overlay.commit_unit(
           Sanctum.Context.actor(ctx),
           AquaPath.crew_file(name),
           {:files, [{[], bytes}]},
           cap: {:checked, byte_size(bytes)},
           if_absent: true
         ) do
      {:ok, _written} ->
        resync_index(ctx)
        {:ok, %{created: name, type: AquaAgent.crew_type()}}

      {:error, :exists} ->
        {:error, {:invalid_argument, "Crew member '#{name}' already exists"}}

      {:error, {:limit_reached, _, _} = reason} ->
        {:error, reason}

      # The store could not say whether the commit landed. The resync
      # reads the tree, so it is right either way.
      {:error, :outcome_unknown} = unknown ->
        resync_index(ctx)
        unknown

      {:error, reason} ->
        passthrough_or_unavailable(reason, "aqua.create #{name}")
    end
  end

  # The digest of a prompt as `get` answers it in `content_digest`, and as
  # `update` compares an `expected_digest` against — so an editor can say
  # which version it edited.
  defp content_digest(content) when is_binary(content), do: Prima.Digest.sha256_hex(content)

  defp check_expected_digest(_agent, nil), do: :ok

  defp check_expected_digest(agent, digest) when is_binary(digest) do
    if content_digest(agent.prompt) == digest do
      :ok
    else
      {:error,
       {:conflict, "The prompt changed since you opened it — reload to see the current one"}}
    end
  end

  defp check_expected_digest(_agent, _digest),
    do: {:error, {:invalid_argument, "expected_digest must be a string"}}

  defp one_tools_argument(%{"tools" => tools} = args) when not is_nil(tools) do
    if is_nil(args["tools_add"]) and is_nil(args["tools_remove"]),
      do: :ok,
      else: {:error, {:invalid_argument, "Give tools, or tools_add and tools_remove, not both"}}
  end

  defp one_tools_argument(_args), do: :ok

  # The soul's list with the edit applied to it as it is when the write
  # lands; `Compendium.AquaAgent.serialize/1` writes it in its one form.
  defp patched_tools(tools, add, remove),
    do: ((tools || []) ++ (add || [])) -- (remove || [])

  # `nil` for an updatable field removes it; an absent key leaves it
  # alone. `content` swaps the prompt body.
  defp apply_updates(agent, args) do
    agent
    |> maybe_update(args, "title", :title, agent.name)
    |> maybe_update(args, "description", :description, "")
    |> maybe_update(args, "avoid", :avoid, "")
    |> maybe_update(args, "mode", :mode, "auto")
    |> maybe_update(args, "tools", :tools, [])
    |> maybe_update(args, "catalyst_ref", :catalyst_ref, nil)
    |> maybe_update(args, "program", :program, nil)
    |> maybe_update(args, "model", :model, nil)
    |> maybe_update(args, "options", :options, %{})
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

  # The soul's own read, out of the list's per-agent errors: a soul whose
  # file the store could not give, or which does not parse, is refused
  # with that error.
  defp soul_read(errors) do
    case List.keyfind(errors, AquaPath.soul_name(), 0) do
      # A soul still holding the retired key, or a `tools` entry that
      # names no one action, is refused in the sentence that says what to
      # change, not as a store's fault.
      {_soul, :tool_policy_retired} ->
        {:error, {:conflict, Prima.AgentRef.tool_policy_retired()}}

      {_soul, {:tools_invalid_entry, entry}} ->
        {:error, {:conflict, Prima.AgentRef.tools_entry_invalid(entry)}}

      {_soul, reason} ->
        {:error, reason}

      nil ->
        :ok
    end
  end

  # First need: an athanor whose fill has not completed is filled the first
  # time something reads its bundle.
  #
  # This tool is where every agent read from outside lands — the roster
  # and one agent's detail, for the console and any MCP client. The turn
  # reads the same tree in-process (`Aqua.AgentConfig.roster/1`) and hooks
  # itself the same way, so whichever reader comes first, the bundle is
  # there before anything roots an authority in it.
  defp ensure_bundle(%Context{} = ctx), do: Sanctum.Provisioning.start_provisioning(ctx)

  defp validate_name(name) do
    if AquaPath.valid_name?(name),
      do: :ok,
      else:
        {:error,
         {:invalid_argument, "Invalid name #{inspect(name)} — use letters, digits, '_' and '-'"}}
  end

  # One rule at this door, `Compendium.AquaAgent.check_tools/1`: the
  # grammar the file parser applies, so nothing this door admits can fail
  # to parse back. An absent argument leaves the list alone
  # (`apply_updates/2`).
  # A member's mode at this door as the file parser reads it, whoever
  # calls it: one of the file's two, so no write lands a mode its next
  # read refuses.
  defp validate_mode(nil), do: :ok

  defp validate_mode(mode) do
    if mode in AquaAgent.modes(),
      do: :ok,
      else: {:error, {:invalid_argument, "mode must be \"read-only\" or \"auto\""}}
  end

  defp validate_tools(nil), do: :ok

  defp validate_tools(tools) do
    case AquaAgent.check_tools(tools) do
      :ok ->
        :ok

      {:error, {:tools_invalid_entry, entry}} ->
        {:error,
         {:invalid_argument,
          "Invalid tool #{inspect(entry)} — use \"tool.action\", \"native_search\" or " <>
            "\"server:tool\", one action an entry: list each action of a tool by name"}}

      {:error, :tools_not_a_list} ->
        {:error, {:invalid_argument, "tools must be a list"}}
    end
  end

  # A crew member is offered the soul's tools and holds none of its own:
  # a write that names some for it is refused, never dropped.
  defp no_crew_tools(name, args) do
    if not AquaPath.soul?(name) and
         Enum.any?(["tools", "tools_add", "tools_remove"], &(not is_nil(args[&1]))),
       do:
         {:error,
          {:invalid_argument,
           "A crew member is offered the soul's tools and has none of its own — edit the soul's"}},
       else: :ok
  end

  # An agent names its brain once (`Compendium.AquaAgent.check_brain/1`):
  # a write that would name both a catalyst and a program is refused here,
  # never landed as a file that would not parse back. On update it is the
  # agent the write makes that is judged, the fields the call leaves out
  # read from the file as it is.
  defp one_brain(agent) do
    case AquaAgent.check_brain(agent) do
      :ok ->
        :ok

      {:error, :catalyst_and_program} ->
        {:error,
         {:invalid_argument,
          "An agent's brain is a catalyst or a program, never both — " <>
            "give catalyst_ref or program, and clear the other"}}
    end
  end

  # A brain's options: named strings, integers and booleans, the kinds a
  # brain declares (`Prima.Model`). Which names and values the brain
  # takes is the brain's to say when a turn opens on it.
  defp validate_options(nil), do: :ok

  defp validate_options(options) when is_map(options) do
    if Enum.all?(options, fn {name, value} ->
         is_binary(name) and name != "" and
           (is_binary(value) or is_integer(value) or is_boolean(value))
       end),
       do: :ok,
       else: {:error, {:invalid_argument, "options are named strings, integers or booleans"}}
  end

  defp validate_options(_options), do: {:error, {:invalid_argument, "options must be an object"}}

  defp one_options_argument(%{"options" => options, "options_patch" => patch})
       when not is_nil(options) and not is_nil(patch),
       do: {:error, {:invalid_argument, "Give options or options_patch, not both"}}

  defp one_options_argument(_args), do: :ok

  # A patch's values are an option's kinds, or null to take one off.
  defp validate_options_patch(nil), do: :ok

  defp validate_options_patch(patch) when is_map(patch) do
    {cleared, set} = Enum.split_with(patch, fn {_name, value} -> is_nil(value) end)

    with :ok <- validate_options(Map.new(set)) do
      if Enum.all?(cleared, fn {name, _} -> is_binary(name) and name != "" end),
        do: :ok,
        else: {:error, {:invalid_argument, "options_patch names options by name"}}
    end
  end

  defp validate_options_patch(_patch),
    do: {:error, {:invalid_argument, "options_patch must be an object"}}

  # Applied to the options the file holds as the write lands, under the
  # rewrite's lock: only the options the patch names change.
  defp patched_options(options, nil), do: options

  defp patched_options(options, patch) do
    Enum.reduce(patch, options || %{}, fn
      {name, nil}, acc -> Map.delete(acc, name)
      {name, value}, acc -> Map.put(acc, name, value)
    end)
  end
end
