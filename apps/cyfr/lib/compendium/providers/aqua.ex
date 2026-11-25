# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.Aqua do
  @moduledoc """
  Aqua tool handlers for the Compendium MCP provider — the soul and its
  crew, the scrolls, and the documentation guides.

  The soul and its crew are the athanor's own: one frontmatter-markdown
  file each — `aqua/aqua.md` and `aqua/crew/<name>.md`, the soul's
  carrying its prompt and a crew member's its frontmatter alone
  (`Compendium.AquaAgent` is the format, `Compendium.AquaPath` the
  layout) — served through the seed overlay: shipped files read through
  until edited, edited ones shadow only themselves, and deleting an
  edited copy reverts it to shipped. Scrolls are Agent Skills kept in
  packs under `aqua/scrolls/<pack>/` (`Compendium.Packs`), each named
  `<pack>:<scroll>`.
  """

  require Logger

  alias Compendium.AquaAgent
  alias Compendium.AquaPath
  alias Sanctum.Context

  # What a save of a proposed new scroll names it made against.
  @against_none "none"

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
    # the `tools` a chain may call and each member's options, its access
    # among them — is a member's act from outside, never something a
    # chain can do to itself.
    # Every write is `consent: :interactive`: a person's own session
    # changes the soul, the crew and the scrolls, never a standing
    # credential — an API key, a `*` key included, is refused at the
    # registry's dispatch gate and does not see these actions in
    # `tools/list`.
    #
    # A scroll is a procedure the athanor learns, and the person writes
    # it. A chain's create or update writes nothing: it answers the scroll
    # as it would be stored and what it was made against, which the
    # thread shows for the person to save from their own session. In-chain
    # the interactive class keeps its surface half, so even the proposal
    # needs an `:oidc`-rooted turn: a schedule- or key-started turn
    # proposes nothing. Deleting stays a member's act alone.
    # Reset restores shipped units — one agent by name, else every
    # edited copy. With all=true it also deletes the crew members and
    # scrolls the athanor made.
    Operation.tool(
      [
        Operation.new(
          "aqua",
          "list",
          "List Aqua, its crew and its guides",
          [
            Arg.new("detail", :boolean,
              description:
                "For list: include each agent's full fields (model, catalyst_ref, program, options, avoid, tools, disabled, and the soul's prompt as content) — one call instead of a get per agent"
            ),
            Arg.new("include_disabled", :boolean,
              description:
                "For list: include crew members set aside with disabled: true, which the roster otherwise leaves out"
            )
          ],
          kind: :read,
          planes: [:external, :in_chain]
        ),
        Operation.new(
          "aqua",
          "get",
          "Read Aqua, a crew member or a guide",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Soul ('aqua'), crew member or guide (for get/update/delete/reset), or a scroll by its pack and its name, like 'mine:research' (for the skill_* actions)"
            )
          ],
          kind: :read,
          planes: [:external, :in_chain]
        ),
        Operation.new(
          "aqua",
          "create",
          "Add a crew member",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Soul ('aqua'), crew member or guide (for get/update/delete/reset), or a scroll by its pack and its name, like 'mine:research' (for the skill_* actions)"
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
                "The name of the program on the Programs page this agent's brain runs in, a driven program with a kept folder, in place of catalyst_ref; a name the athanor has no program of yet is kept, and the agent's card offers to install it (for create/update actions)"
            ),
            Arg.new("model", :string,
              description: "Model identifier (for create/update actions)"
            ),
            Arg.new("avoid", :string,
              description:
                "What the soul should never hand a crew member (create/update; crew members only)"
            ),
            Arg.new("options", {:map, Arg.new(nil, :json)},
              description:
                "The options this agent's brain is asked with on every request — names and values its describe declares (create/update)"
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
          "Change Aqua or a crew member",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Soul ('aqua'), crew member or guide (for get/update/delete/reset), or a scroll by its pack and its name, like 'mine:research' (for the skill_* actions)"
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
                "The name of the program on the Programs page this agent's brain runs in, a driven program with a kept folder, in place of catalyst_ref; a name the athanor has no program of yet is kept, and the agent's card offers to install it (for create/update actions)"
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
                "The options this agent's brain is asked with on every request — names and values its describe declares; for a program brain, 'effort' and 'access', each one of the values its program lists (create/update)"
            ),
            Arg.new("options_patch", {:map, Arg.new(nil, :json, nullable: true)},
              description:
                "update only: the brain options to change, applied to the options as they are when the write lands — a value sets an option, null takes it off; options not named are kept, so two edits of different options at once keep both. Not with options."
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
                "The soul's prompt in markdown (update; a crew member has none: how it does a kind of job is a scroll), or the scroll's body (skill_create/skill_update)"
            ),
            Arg.new("disabled", :boolean,
              nullable: true,
              description:
                "Take a crew member out of the crew without deleting its file (for update; shipped members cannot be deleted — disable them instead)"
            ),
            Arg.new("member", :string,
              nullable: true,
              description:
                "update only, the soul ('aqua'): the crew member Aqua runs on, whose brain, model and options it takes; null names none. The soul has no brain of its own."
            ),
            Arg.new("expected_digest", :string,
              description:
                "update only: the content_digest that get answered for the soul's prompt being edited. The update is refused as a conflict when the prompt has changed since, so one edit never writes over another."
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
          "Remove a crew member",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Soul ('aqua'), crew member or guide (for get/update/delete/reset), or a scroll by its pack and its name, like 'mine:research' (for the skill_* actions)"
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
          "Restore Aqua's shipped files",
          [
            Arg.new("name", :string,
              description:
                "Soul ('aqua'), crew member or guide (for get/update/delete/reset), or a scroll by its pack and its name, like 'mine:research' (for the skill_* actions)"
            ),
            Arg.new("all", :boolean,
              description:
                "For reset: also DELETE the crew members the athanor made, so the soul and the crew become exactly the shipped set (default false keeps them). Reset never touches a pack of scrolls"
            )
          ],
          kind: :destructive,
          planes: [:external],
          consent: :interactive,
          permission: :component_manage
        ),
        Operation.new("aqua", "status", "Where each of Aqua's files came from", [],
          kind: :read,
          planes: [:external, :in_chain]
        ),
        Operation.new("aqua", "skill_list", "List scrolls", [],
          kind: :read,
          planes: [:external, :in_chain],
          recovery: :replay_safe
        ),
        Operation.new(
          "aqua",
          "skill_get",
          "Read a scroll",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Soul ('aqua'), crew member or guide (for get/update/delete/reset), or a scroll by its pack and its name, like 'mine:research' (for the skill_* actions)"
            ),
            Arg.new("path", :string,
              description:
                "skill_get: one file of the scroll's pack by its path inside the pack, like 'skills/research/scripts/fetch.sh'; read as outside material"
            )
          ],
          kind: :read,
          planes: [:external, :in_chain],
          recovery: :replay_safe
        ),
        Operation.new(
          "aqua",
          "skill_create",
          "Write a new scroll",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Soul ('aqua'), crew member or guide (for get/update/delete/reset), or a scroll by its pack and its name, like 'mine:research' (for the skill_* actions)"
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
                "The soul's prompt in markdown (update; a crew member has none: how it does a kind of job is a scroll), or the scroll's body (skill_create/skill_update)"
            ),
            Arg.new("against", :string,
              description:
                "skill_create/skill_update from a person's Save as scroll: what the proposal was made against, the stored scroll's digest for an update or none for a create; the write is refused when the scroll changed since"
            ),
            Arg.new("new_pack", :boolean,
              description:
                "skill_create from a person's New pack: the scroll is its pack's first, and the write is refused when a pack of that name is already here (default false writes into the pack, making it when there is none)"
            )
          ],
          kind: :write,
          planes: [:external, :in_chain],
          consent: :interactive,
          permission: :component_manage
        ),
        Operation.new(
          "aqua",
          "skill_update",
          "Change a scroll",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Soul ('aqua'), crew member or guide (for get/update/delete/reset), or a scroll by its pack and its name, like 'mine:research' (for the skill_* actions)"
            ),
            Arg.new("description", :string,
              description:
                "What a crew member is good at, which the soul reads when it hands a job (create/update), or the one line a scroll's index shows (skill_create/skill_update)"
            ),
            Arg.new("content", :string,
              bulk: true,
              description:
                "The soul's prompt in markdown (update; a crew member has none: how it does a kind of job is a scroll), or the scroll's body (skill_create/skill_update)"
            ),
            Arg.new("against", :string,
              description:
                "skill_create/skill_update from a person's Save as scroll: what the proposal was made against, the stored scroll's digest for an update or none for a create; the write is refused when the scroll changed since"
            )
          ],
          kind: :write,
          planes: [:external, :in_chain],
          consent: :interactive,
          permission: :component_manage
        ),
        Operation.new(
          "aqua",
          "skill_delete",
          "Remove a scroll",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Soul ('aqua'), crew member or guide (for get/update/delete/reset), or a scroll by its pack and its name, like 'mine:research' (for the skill_* actions)"
            )
          ],
          kind: :destructive,
          planes: [:external],
          consent: :interactive,
          permission: :component_manage
        ),
        # A turn's wait for a time, held as long as it takes
        # (`Prima.Operation`'s `waits`): no effect, so a post answers it
        # early and a restart waits out what is left.
        Operation.new(
          "aqua",
          "wait",
          "Wait until a time",
          [
            Arg.new("until", :string,
              required: true,
              description:
                "wait: the time to wait until, ISO 8601 with its offset, e.g. '2026-11-26T09:00:00+01:00'; a time already past answers at once"
            )
          ],
          kind: :read,
          planes: [:in_chain],
          consent: :interactive,
          recovery: :replay_safe,
          waits: true
        )
      ],
      description:
        "The athanor's Aqua: one soul (the assistant, reserved name 'aqua', which runs on the brain of the crew member its member names), the crew it hands jobs to through crew.ask (each a brain with what it is good at and what to avoid, offered the soul's tools), the scrolls it has learned, and the documentation guides. Use 'list' to see the soul, crew and guides, 'get' to read one (the soul by name 'aqua'), 'create'/'update'/'delete' to manage crew members ('aqua' cannot be created or deleted — edit it, or reset), 'status' for per-file provenance, 'skill_list'/'skill_get' to read scrolls (Agent Skills kept in packs under aqua/scrolls/<pack>/, each named '<pack>:<scroll>'), 'skill_create'/'skill_update' to write one in a pack of the person's own, 'skill_delete' to remove one there, 'wait' to wait in a turn until a time (a message from the person ends the wait early), or 'reset' to restore edited copies of shipped files (one agent with name, else every one; crew members the athanor made are kept unless all=true; packs are not reset).",
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
    # stays out of the crew; one refused for instructions below its
    # frontmatter is named under `refused` with the sentence that says what
    # to change, so the person can act on it.
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
            base
            |> Map.merge(%{
              model: agent.model,
              catalyst_ref: agent.catalyst_ref,
              program: agent.program,
              options: agent.options,
              avoid: agent.avoid,
              tools: agent.tools,
              disabled: agent.disabled
            })
            |> Map.merge(seat_fields(agent))
            |> then(
              &if(is_binary(agent.prompt), do: Map.put(&1, :content, agent.prompt), else: &1)
            )
          else
            base
          end
        end)

      # The soul first, then the crew, then the guides.
      all = agent_guides ++ doc_guides

      refused =
        for {name, :crew_has_no_prompt} <- errors,
            do: %{name: name, reason: AquaAgent.prompt_refused(name)}

      {:ok, %{guides: all, count: length(all), refused: refused}}
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
      # The soul's prompt and its digest, which an editor names to save
      # over it; a crew member has no prompt to show or edit.
      prompt =
        case agent.prompt do
          nil -> %{}
          prompt -> %{content: prompt, content_digest: content_digest(prompt)}
        end

      {:ok,
       Map.merge(prompt, %{
         name: agent.name,
         format: "markdown",
         type: AquaAgent.type_of(agent),
         title: agent.title,
         description: agent.description,
         avoid: agent.avoid,
         tools: agent.tools,
         catalyst_ref: agent.catalyst_ref,
         program: agent.program,
         model: agent.model,
         options: agent.options,
         disabled: agent.disabled
       })
       |> Map.merge(seat_fields(agent))}
    else
      {:error, :not_found} ->
        {:error, {:not_found, "Soul, crew member or guide", name}}

      {:error, :crew_has_no_prompt} ->
        {:error, {:conflict, AquaAgent.prompt_refused(name)}}

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
         :ok <- no_crew_prompt(name, args),
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
         :ok <- no_crew_prompt(name, args),
         :ok <- no_seat_brain(name, args),
         :ok <- validate_member(name, args),
         :ok <- one_tools_argument(args),
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
        {:error, {:not_found, "Aqua or crew member", name}}

      {:error, :crew_has_no_prompt} ->
        {:error, {:conflict, AquaAgent.prompt_refused(name)}}

      {:error, :seat_has_brain} ->
        {:error, {:conflict, Prima.AgentRef.seat_has_brain()}}

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
          {:error, {:not_found, "Aqua or crew member", name}}

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
      restore_unit(ctx, AquaPath.agent_file(name), "Aqua or crew member", name)
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

  # The index is `Compendium.Packs`' — the same read the turn's prompt
  # makes in-process, so the tool and the prompt cannot list two
  # different sets of scrolls. It lists the scrolls of the packs
  # switched on, by their full names.
  def handle(%Context{} = ctx, %{"action" => "skill_list"}) do
    case Compendium.Packs.index(ctx) do
      {:ok, []} ->
        {:ok,
         %{
           skills: [],
           count: 0,
           hint:
             "No scrolls in the packs switched on. A scroll is named by its pack and its " <>
               "name, like mine:research; the person keeps packs on the Aqua page's Scrolls."
         }}

      {:ok, skills} ->
        skills = listed(ctx, skills)
        {:ok, %{skills: Enum.map(skills, &listed_entry/1), count: length(skills)}}

      {:error, reason} ->
        Logger.error("[Compendium.Providers.Aqua] aqua.skill_list failed: #{inspect(reason)}")
        {:error, {:unavailable, "Storage"}}
    end
  end

  # One file of a scroll's pack by its path, outside material: a text file
  # whole or cut at the bound with a note, a binary by its type and size.
  def handle(%Context{} = ctx, %{"action" => "skill_get", "name" => name, "path" => path})
      when is_binary(path) do
    case Compendium.Packs.file(ctx, name, path) do
      {:ok, %{format: "text"} = file} ->
        {:ok,
         %{
           name: file.name,
           path: file.path,
           size: file.size,
           format: "text",
           content: file.content
         }
         |> then(&if(file.cut, do: Map.put(&1, :note, cut_note(file)), else: &1))}

      {:ok, %{format: "binary"} = file} ->
        {:ok,
         %{
           name: file.name,
           path: file.path,
           size: file.size,
           format: "binary",
           type: file.type,
           note: "A binary file of #{file.size} bytes (#{file.type}): not shown."
         }}

      {:error, :not_found} ->
        {:error, {:not_found, "File", "#{name} #{path}"}}

      {:error, reason} ->
        passthrough_or_unavailable(reason, "aqua.skill_get #{name} #{path}")
    end
  end

  # The one read of a scroll by name (`Compendium.skill/2`). A chain is
  # never handed a scroll past the bound (`Compendium.Packs`); the
  # Scrolls editor reads it from outside, to show it and say why.
  def handle(%Context{} = ctx, %{"action" => "skill_get", "name" => name}) do
    with {:ok, scroll} <- Compendium.skill(ctx, name),
         :ok <- carried(ctx, scroll) do
      {:ok,
       %{
         name: scroll.name,
         title: scroll.title,
         description: scroll.description,
         format: "markdown",
         content: scroll.body,
         resources: scroll.files,
         kept: scroll.kept
       }}
    else
      {:error, :not_found} ->
        {:error, {:not_found, "Scroll", to_string(name)}}

      {:error, {:invalid_argument, _} = refusal} ->
        {:error, refusal}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        passthrough_or_unavailable(reason, "aqua.skill_get #{inspect(name)}")
    end
  end

  # A chain's create writes nothing: it answers the scroll as it would be
  # stored, made against no scroll of its name, for the person to save.
  def handle(%Context{plane: :guest} = ctx, %{"action" => "skill_create", "name" => name} = args) do
    with {:ok, pack, scroll} <- scroll_name(ctx, name),
         :ok <- own_pack(ctx, pack),
         {:ok, _manifest} <- skill_manifest_bytes(scroll, args["description"], args["content"]),
         :ok <- untaken(ctx, name) do
      proposal = proposal(name, args["description"], args["content"], @against_none)

      # A proposal carries everything Save needs: one that makes a new pack
      # says so, and Save is then create-only, refused when the pack is
      # there, as the page's own New pack is.
      {:ok, if(args["new_pack"] == true, do: Map.put(proposal, :new_pack, true), else: proposal)}
    end
  end

  # A scroll is a folder of its pack, `skills/<scroll>/SKILL.md`. Creating
  # one is a write into the pack as every write into it is
  # (`Compendium.Packs.put_scroll/4`, under `Compendium.Packs.admit_edit/4`):
  # into a pack of the person's own, which the write makes when there is
  # none of that name, and never into a brought pack or `cyfr`. The write
  # asks whether the name is taken while it holds the pack's draft, so two
  # creators of one name cannot both land. A save of a proposal names it
  # made against none, the one thing a create can be made against.
  def handle(%Context{} = ctx, %{"action" => "skill_create", "name" => name} = args) do
    with {:ok, _pack, scroll} <- scroll_name(ctx, name),
         :ok <- against_none(args),
         {:ok, manifest} <- skill_manifest_bytes(scroll, args["description"], args["content"]) do
      mode = if args["new_pack"] == true, do: :new_pack, else: :create

      case Compendium.Packs.put_scroll(ctx, name, manifest, mode) do
        :ok ->
          {:ok, %{created: name}}

        {:error, {:invalid_argument, _} = refusal} ->
          {:error, refusal}

        {:error, {:limit_reached, _, _} = reason} ->
          {:error, reason}

        {:error, reason} ->
          passthrough_or_unavailable(reason, "aqua.skill_create #{name}")
      end
    end
  end

  # A chain's update writes nothing either: it answers the whole scroll as
  # the update would store it, the fields the call leaves out read now,
  # and the digest of the stored manifest it was made against.
  def handle(%Context{plane: :guest} = ctx, %{"action" => "skill_update", "name" => name} = args) do
    with {:ok, pack, scroll} <- scroll_name(ctx, name),
         {:ok, %{bytes: current, origin: origin}} <- Compendium.Packs.manifest(ctx, name),
         :ok <- own_origin(pack, origin),
         {:ok, meta, body} <- AquaAgent.parse_frontmatter(current),
         description = Map.get(args, "description", meta["description"]),
         content = Map.get(args, "content", body),
         {:ok, _manifest} <- skill_manifest_bytes(scroll, description, content) do
      {:ok, proposal(name, description, content, Prima.Digest.sha256(current))}
    else
      {:error, :not_found} ->
        {:error, {:not_found, "Scroll", name}}

      {:error, {:invalid_argument, _} = refusal} ->
        {:error, refusal}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        passthrough_or_unavailable(reason, "aqua.skill_update #{name}")
    end
  end

  # Updating rewrites the manifest alone, under the pack's draft: the
  # fields the call leaves out are read from the manifest as it is at the
  # moment of the write, so two concurrent updates cannot lose one, and a
  # save of a proposal is refused, inside the same write, when the
  # manifest is no longer the one it was made against. The scroll's other
  # files stay.
  def handle(%Context{} = ctx, %{"action" => "skill_update", "name" => name} = args) do
    with {:ok, _pack, scroll} <- scroll_name(ctx, name) do
      rewrite = fn current ->
        with :ok <- unchanged(name, current, args["against"]),
             {:ok, meta, body} <- AquaAgent.parse_frontmatter(current) do
          skill_manifest_bytes(
            scroll,
            Map.get(args, "description", meta["description"]),
            Map.get(args, "content", body)
          )
        end
      end

      case Compendium.Packs.put_scroll(ctx, name, nil, {:update, rewrite}) do
        :ok ->
          {:ok, %{updated: name}}

        {:error, :not_found} ->
          {:error, {:not_found, "Scroll", name}}

        {:error, {:invalid_argument, _} = refusal} ->
          {:error, refusal}

        {:error, {:conflict, _} = refusal} ->
          {:error, refusal}

        {:error, {:limit_reached, _, _} = reason} ->
          {:error, reason}

        {:error, reason} when is_binary(reason) ->
          {:error, reason}

        {:error, reason} ->
          passthrough_or_unavailable(reason, "aqua.skill_update #{name}")
      end
    end
  end

  # A scroll's folder goes whole, as a delete through Files takes it: a
  # write into its pack, which a brought pack and `cyfr` refuse.
  def handle(%Context{} = ctx, %{"action" => "skill_delete", "name" => name}) do
    with {:ok, pack, _scroll} <- scroll_name(ctx, name),
         {:ok, %{folder: folder}} <- Compendium.Packs.manifest(ctx, name) do
      case Arca.delete_tree(Sanctum.Context.actor(ctx), AquaPath.scroll_dir(pack, folder)) do
        :ok ->
          {:ok, %{deleted: name}}

        {:error, {:invalid_argument, _} = refusal} ->
          {:error, refusal}

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
    else
      {:error, :not_found} -> {:error, {:not_found, "Scroll", name}}
      {:error, _} = refused -> refused
    end
  end

  # --- wait ---

  # A turn's own call, as `program.wait` is: the person's running turn,
  # by the store's one rule (`Arca.TurnStorage.own_turn/3`), never a
  # component's or a page's. Held in the gate's handler process until the
  # time, which the gate bounds by nothing but the call's end
  # (`waits: true`): the turn's end, a Stop, a lost lease or a post
  # (`Aqua.Loop`) stop it.
  def handle(%Context{} = ctx, %{"action" => "wait", "until" => until} = args)
      when is_binary(until) do
    with :ok <- waiting_turn(ctx, args) do
      case DateTime.from_iso8601(until) do
        {:ok, due, _offset} ->
          :ok = wait_until(due)
          {:ok, %{until: DateTime.to_iso8601(due), now: DateTime.to_iso8601(DateTime.utc_now())}}

        {:error, _unparsed} ->
          {:error,
           {:invalid_argument,
            "aqua.wait: until must be an ISO 8601 time with its offset, like 2026-11-26T09:00:00+01:00"}}
      end
    end
  end

  # --- helpers ---

  defp waiting_turn(%Context{plane: :guest, user_id: user_id} = ctx, args)
       when is_binary(user_id) do
    case Arca.TurnStorage.own_turn(Sanctum.Context.actor(ctx), user_id, args) do
      {:ok, %{status: "running"}} ->
        :ok

      {:ok, _not_running} ->
        {:error, :wait_not_a_turn}

      {:error, reason} when reason in [:by_page, :by_component, :not_open] ->
        {:error, :wait_not_a_turn}

      {:error, _unread} ->
        {:error, {:unavailable, "Storage"}}
    end
  end

  defp waiting_turn(_ctx, _args), do: {:error, :wait_not_a_turn}

  # The longest one `receive ... after` holds; a longer wait is held in
  # steps, each measured again from the clock.
  @wait_step_ms 3_600_000

  defp wait_until(due) do
    case DateTime.diff(due, DateTime.utc_now(), :microsecond) do
      left when left > 0 ->
        receive do
        after
          min(div(left + 999, 1000), @wait_step_ms) -> wait_until(due)
        end

      _due ->
        :ok
    end
  end

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
      tools: [],
      prompt: nil,
      member: nil,
      holder: nil
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
  # alone. `content` swaps the soul's prompt (`no_crew_prompt/2` refuses
  # it for a crew member).
  defp apply_updates(agent, args) do
    agent
    |> maybe_update(args, "title", :title, agent.name)
    |> maybe_update(args, "description", :description, "")
    |> maybe_update(args, "avoid", :avoid, "")
    |> maybe_update(args, "tools", :tools, [])
    |> maybe_update(args, "catalyst_ref", :catalyst_ref, nil)
    |> maybe_update(args, "program", :program, nil)
    |> maybe_update(args, "model", :model, nil)
    |> maybe_update(args, "options", :options, %{})
    |> maybe_update(args, "disabled", :disabled, false)
    |> maybe_update(args, "member", :member, nil)
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

  # The Agent Skills manifest: frontmatter `name` (the scroll's, its folder's) and a
  # one-line `description` (what the index shows), then the body. Both
  # are required — a scroll nobody can find by its line is not a scroll —
  # and the whole is within the bound every harness carries
  # (`Compendium.Packs`). Values are JSON-encoded, the one YAML
  # scalar spelling that survives any description.
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
        manifest =
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
          ])

        if Compendium.Packs.fits?(byte_size(manifest), description),
          do: {:ok, manifest},
          else: {:error, {:invalid_argument, too_large(name)}}
    end
  end

  defp too_large(name),
    do:
      "The scroll '#{name}' is too large for Aqua to use: a scroll, its files' names " <>
        "with it, holds at most #{Compendium.Packs.max_bytes()} bytes and its " <>
        "description at most #{Compendium.Packs.max_description()} characters"

  defp taken(name), do: "Scroll '#{name}' already exists"

  # A chain is never handed a scroll past the bound; the person's own
  # session reads it, to see it and change it.
  defp carried(%Context{plane: :guest}, %{carried: false, name: name}),
    do: {:error, {:invalid_argument, too_large(name)}}

  defp carried(_ctx, _scroll), do: :ok

  # A chain's listing leaves out what no harness carries, as its index does.
  defp listed(%Context{plane: :guest}, skills), do: Enum.filter(skills, & &1.carried)
  defp listed(_ctx, skills), do: skills

  # A chain's proposal of a create names a scroll the athanor has none of
  # yet, as the save's write will ask under the pack's draft.
  defp untaken(ctx, name) do
    case Compendium.Packs.manifest(ctx, name) do
      {:ok, _manifest} -> {:error, {:invalid_argument, taken(name)}}
      {:error, :not_found} -> :ok
      {:error, reason} -> passthrough_or_unavailable(reason, "aqua.skill_create #{name}")
    end
  end

  # A scroll's name at this door: its pack and its name. A bare name is
  # refused with the sentence naming the full names it matches
  # (`Compendium.Packs.bare_refusal/2`).
  defp scroll_name(ctx, name) do
    case Compendium.Packs.split_name(name) do
      {:ok, pack, scroll} ->
        {:ok, pack, scroll}

      {:bare, bare} ->
        Compendium.Packs.bare_refusal(Sanctum.Context.actor(ctx), bare)

      :error ->
        {:error,
         {:invalid_argument,
          "Invalid scroll name #{inspect(name)} — a scroll is named by its pack and its name, " <>
            "like mine:research, each of letters, digits, '_' and '-'"}}
    end
  end

  # A turn proposes only into a pack of the person's own, or one its save
  # would make.
  defp own_pack(ctx, pack) do
    case Compendium.Packs.pack(ctx, pack) do
      {:ok, %{origin: origin}} ->
        own_origin(pack, origin)

      {:error, :not_found} ->
        if pack == Compendium.Packs.cyfr(), do: own_origin(pack, "cyfr"), else: :ok
    end
  end

  defp own_origin(_pack, "own"), do: :ok
  defp own_origin(pack, origin), do: {:error, Compendium.Packs.sealed(pack, origin || "brought")}

  defp listed_entry(entry),
    do: Map.take(entry, [:name, :title, :description, :carried, :kept])

  defp cut_note(file),
    do:
      "The file holds #{file.size} bytes; the first #{byte_size(file.content)} are shown, " <>
        "cut at a scroll's bound."

  # What a chain answers in place of a write: the whole scroll as it would
  # be stored, and what it was made against, which a save sends back.
  defp proposal(name, description, content, against) do
    %{
      proposed: name,
      description: String.trim(description),
      content: String.trim(content),
      against: against,
      note: "Nothing is written: this waits in the thread for the person to save it as a scroll."
    }
  end

  defp against_none(%{"against" => against}) when against not in [nil, @against_none],
    do: {:error, {:invalid_argument, "A new scroll is made against none"}}

  defp against_none(_args), do: :ok

  # A save of a proposal writes only over the manifest it was made against.
  defp unchanged(_name, _current, nil), do: :ok

  defp unchanged(name, current, against) do
    if Prima.Digest.sha256(current) == against,
      do: :ok,
      else:
        {:error,
         {:conflict,
          "The scroll '#{name}' changed since Aqua proposed this, so nothing was saved: " <>
            "open it from Scrolls to see it as it is now"}}
  end

  # What the soul says of the crew member it runs on: its name, and while
  # that member does not supply its brain, the sentence its turn is
  # refused with (`Prima.Refusal`). A crew member says nothing of it.
  defp seat_fields(%{holder: %{state: :held}, member: member}), do: %{member: member}

  defp seat_fields(%{holder: %{state: state, name: holder}, member: member}),
    do: %{member: member, member_refusal: Prima.Refusal.message({:aqua_runs_on, state, holder})}

  defp seat_fields(_crew), do: %{}

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

      {_soul, :seat_has_brain} ->
        {:error, {:conflict, Prima.AgentRef.seat_has_brain()}}

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

  # A crew member has no prompt (`Compendium.AquaAgent`): a write that
  # gives one is refused, never dropped, with where its words belong.
  defp no_crew_prompt(name, args) do
    if not AquaPath.soul?(name) and
         Enum.any?(["content", "expected_digest"], &(not is_nil(args[&1]))),
       do:
         {:error,
          {:invalid_argument,
           "A crew member has no prompt: the job it is handed says what to do, and how a " <>
             "kind of job is done is a scroll — write one with skill_create"}},
       else: :ok
  end

  # The soul runs on the crew member it names and has no brain of its
  # own (`Compendium.AquaAgent`): a write that gives it one is refused,
  # never dropped, with where the brain is set instead. A crew member
  # names no member.
  @seat_brain_args ~w(catalyst_ref program model options options_patch)

  defp no_seat_brain(name, args) do
    cond do
      AquaPath.soul?(name) and Enum.any?(@seat_brain_args, &(not is_nil(args[&1]))) ->
        {:error,
         {:invalid_argument,
          "Aqua has no brain of its own: it runs on the crew member `member` names — set " <>
            "member, and the brain, model and options on that member"}}

      not AquaPath.soul?(name) and not is_nil(args["member"]) ->
        {:error,
         {:invalid_argument, "Only Aqua runs on a crew member: member is set on 'aqua' alone"}}

      true ->
        :ok
    end
  end

  # The member the soul runs on is named as the tree names a crew
  # member's file, and is never the soul itself.
  defp validate_member(name, %{"member" => member}) when is_binary(member) do
    if AquaPath.soul?(name) and AquaAgent.member_name?(member),
      do: :ok,
      else: {:error, {:invalid_argument, "member names a crew member, by its file's name"}}
  end

  defp validate_member(_name, _args), do: :ok

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
