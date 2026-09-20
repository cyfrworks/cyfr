# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.MCP.AquaTool do
  @moduledoc """
  AQUA tool handlers for the Compendium MCP provider — the soul and its
  roles, the scrolls, and the documentation guides.

  The soul and its roles are the athanor's own: one frontmatter-markdown
  file each — `aqua/aqua.md` and `aqua/roles/<name>.md`
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
    alias Cyfr.Ops.{Arg, Operation}
    # The soul and the roles are the athanor's own. Reading them is
    # open to any authenticated caller, a running chain included —
    # a turn resolves its agent through `get`, so the reads
    # carry no consent class and stay reachable from every surface
    # that can start one. Editing them — the closet, the prompts,
    # the `tool_policy` that decides what a chain may call — is a
    # member's act from outside, never something a chain can do to
    # itself.
    # Every write is `consent: :interactive`: a person's own session
    # changes the soul, the closet and the scrolls, never a standing
    # credential — an API key, a `*` key included, is refused at the
    # registry's dispatch gate and does not see these actions in
    # `tools/list`.
    #
    # A scroll is a procedure the estate learns. Writing one is a
    # member's act at the door and a card from a chain — the soul's
    # policy holds both writes at `ask`, so an agent proposes a
    # scroll and a person clicks. In-chain the interactive class
    # keeps its surface half, so the proposal needs an `:oidc`-rooted
    # turn: a schedule- or key-started turn cannot write a scroll,
    # exactly like a note. And a scroll is read into every turn's
    # prompt index, so each write deserves its own click — no
    # standing "Always" at any scope (`standing: false`). Deleting
    # stays a member's act alone: never proposable, never standing.
    # Reset restores shipped units — one role by name, else every
    # edited copy. With all=true it also deletes member-created
    # roles and scrolls.
    Operation.tool(
      [
        Operation.new(
          "aqua",
          "list",
          "List aqua",
          [
            Arg.new("detail", :boolean,
              description:
                "For list: include each agent's full fields (model, tool_policy, catalyst_ref, content, disabled) — one call instead of a get per agent"
            ),
            Arg.new("include_disabled", :boolean,
              description:
                "For list: include roles set aside with disabled: true, which the roster otherwise leaves out"
            )
          ],
          kind: :read,
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
                "Soul ('aqua'), role, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
            )
          ],
          kind: :read,
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
                "Soul ('aqua'), role, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
            ),
            Arg.new("title", :string,
              description: "Human-readable title (for create/update actions)"
            ),
            Arg.new("description", :string,
              description:
                "Role description the soul reads when choosing a role (create/update), or the one line a scroll's index shows (skill_create/skill_update)"
            ),
            Arg.new("catalyst_ref", :string,
              description: "Versionless catalyst reference (for create/update actions)"
            ),
            Arg.new("model", :string,
              description: "Model identifier (for create/update actions)"
            ),
            Arg.new("tool_policy", {:map, Arg.new(nil, :string, enum: ["ask", "auto"])},
              description:
                "Per-(tool,action) allowlist for this agent. Keys are 'tool.action' or 'tool.*' strings (a bare 'native_search' key grants the provider-native search tool); values are 'auto' (directly callable) or 'ask' (reachable only through user approval). A pair missing from the map is not callable at all. Each action's risk level is derived from its `kind` annotation (read/write/execute/destructive/external) — color/UI treatment uses the kind, not the policy mode. The policy is the athanor's: every member edits the same allowlist."
            ),
            Arg.new("content", :string,
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
                "Soul ('aqua'), role, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
            ),
            Arg.new("title", :string,
              nullable: true,
              description: "Human-readable title (for create/update actions)"
            ),
            Arg.new("description", :string,
              nullable: true,
              description:
                "Role description the soul reads when choosing a role (create/update), or the one line a scroll's index shows (skill_create/skill_update)"
            ),
            Arg.new("catalyst_ref", :string,
              nullable: true,
              description: "Versionless catalyst reference (for create/update actions)"
            ),
            Arg.new("model", :string,
              nullable: true,
              description: "Model identifier (for create/update actions)"
            ),
            Arg.new("tool_policy", {:map, Arg.new(nil, :string, enum: ["ask", "auto"])},
              nullable: true,
              description:
                "Per-(tool,action) allowlist for this agent. Keys are 'tool.action' or 'tool.*' strings (a bare 'native_search' key grants the provider-native search tool); values are 'auto' (directly callable) or 'ask' (reachable only through user approval). A pair missing from the map is not callable at all. Each action's risk level is derived from its `kind` annotation (read/write/execute/destructive/external) — color/UI treatment uses the kind, not the policy mode. The policy is the athanor's: every member edits the same allowlist."
            ),
            Arg.new(
              "tool_policy_patch",
              {:map, Arg.new(nil, :string, nullable: true, enum: ["ask", "auto", nil])},
              description:
                "update only: the allowlist keys to change, applied to the policy as it is when the write lands — 'ask' or 'auto' sets a key, null takes it off; keys not named are kept. Two members editing different keys at once keep both. Not with tool_policy."
            ),
            Arg.new("content", :string,
              description:
                "Prompt content in markdown (create/update), or the scroll's body (skill_create/skill_update)"
            ),
            Arg.new("disabled", :boolean,
              nullable: true,
              description:
                "Take a role out of the closet without deleting its file (for update; shipped roles cannot be deleted — disable them instead)"
            ),
            Arg.new("expected_digest", :string,
              description:
                "update only: the content_digest that get answered for the prompt being edited. The update is refused as a conflict when the prompt has changed since, so one member's edit never writes over another's."
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
                "Soul ('aqua'), role, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
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
                "Soul ('aqua'), role, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
            ),
            Arg.new("all", :boolean,
              description:
                "For reset: also DELETE member-created roles and scrolls, so the tree becomes exactly the shipped set (default false keeps them)"
            )
          ],
          kind: :destructive,
          planes: [:external],
          consent: :interactive,
          permission: :component_manage
        ),
        Operation.new("aqua", "status", "Status aqua", [],
          kind: :read,
          planes: [:external, :in_chain]
        ),
        Operation.new("aqua", "skill_list", "Skill list aqua", [],
          kind: :read,
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
                "Soul ('aqua'), role, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
            )
          ],
          kind: :read,
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
                "Soul ('aqua'), role, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
            ),
            Arg.new("description", :string,
              required: true,
              description:
                "Role description the soul reads when choosing a role (create/update), or the one line a scroll's index shows (skill_create/skill_update)"
            ),
            Arg.new("content", :string,
              required: true,
              description:
                "Prompt content in markdown (create/update), or the scroll's body (skill_create/skill_update)"
            )
          ],
          kind: :write,
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
                "Soul ('aqua'), role, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
            ),
            Arg.new("description", :string,
              description:
                "Role description the soul reads when choosing a role (create/update), or the one line a scroll's index shows (skill_create/skill_update)"
            ),
            Arg.new("content", :string,
              description:
                "Prompt content in markdown (create/update), or the scroll's body (skill_create/skill_update)"
            )
          ],
          kind: :write,
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
                "Soul ('aqua'), role, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
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
                "Soul ('aqua'), role, guide, or scroll name (for get/update/delete/reset and the skill_* actions)"
            )
          ],
          kind: :destructive,
          planes: [:external],
          consent: :interactive,
          permission: :component_manage
        )
      ],
      description:
        "The estate's AQUA: one soul (the assistant, reserved name 'aqua'), a flat closet of roles it clones into, the scrolls it has learned, and the documentation guides. Use 'list' to see the soul, roles and guides, 'get' to read one (the soul by name 'aqua'), 'create'/'update'/'delete' to manage roles ('aqua' cannot be created or deleted — edit it, or reset), 'status' for per-file provenance, 'skill_list'/'skill_get' to read scrolls (Agent Skills under aqua/skills/<name>/SKILL.md), 'skill_create'/'skill_update' to write one, 'skill_delete' to remove one the estate made, 'skill_reset' to restore an edited scroll to what ships, or 'reset' to restore edited copies of shipped files (one role with name, else every one; member-created roles and scrolls are kept unless all=true).",
      title: "AQUA Agent System"
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

    agent_guides =
      case AquaAgent.list(ctx) do
        {:ok, agents, _errors} ->
          # The detail flag widens the projection of the already-loaded agents.
          detail? = args["detail"] == true
          # Disabled roles are out of the closet: the model's roster never
          # holds them. A page that puts them back asks for them by flag,
          # in the same read, rather than by a `get` per file.
          include_disabled? = args["include_disabled"] == true

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
                tool_policy: agent.tool_policy,
                content: agent.prompt,
                disabled: agent.disabled
              })
            else
              base
            end
          end)

        _ ->
          []
      end

    # The soul first, then the roles, then the guides.
    all = agent_guides ++ doc_guides

    {:ok, %{guides: all, count: length(all)}}
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
         tool_policy: agent.tool_policy,
         catalyst_ref: agent.catalyst_ref,
         model: agent.model,
         disabled: agent.disabled,
         content_digest: content_digest(agent.prompt)
       }}
    else
      {:error, :not_found} ->
        {:error, {:not_found, "Soul, role or guide", name}}

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
  # A role, flat in the closet. The soul is never created: its name is
  # reserved, it ships with the server, and `update` is how it changes.

  def handle(%Context{} = ctx, %{"action" => "create", "name" => name} = args) do
    with :ok <- validate_name(name),
         :ok <- refute_reserved(name),
         :ok <- validate_tool_policy(args["tool_policy"], AquaAgent.role_type()) do
      create_role(ctx, name, args)
    end
  end

  def handle(_ctx, %{"action" => "create"}) do
    {:error, {:invalid_argument, "Missing required argument: name"}}
  end

  # --- update ---

  # One serialized read-modify-write, like a scroll's: two members
  # editing the same role at once each see the other's bytes, never
  # overwrite them, because the write is made only while the file still
  # holds the bytes the edit was given. Two edits meet in two ways. An
  # allowlist edit arrives as `tool_policy_patch` — the keys it names,
  # `nil` to take one off — applied to the policy as it is at the moment
  # of the write and judged as the whole it makes, so two members
  # toggling different keys at once keep both;
  # `tool_policy` still replaces the map for a caller that means to. A
  # prompt edit may carry `expected_digest` (the `content_digest` `get`
  # answered) and is refused as a conflict when the prompt has changed
  # since, rather than writing over the other member's words.
  def handle(%Context{} = ctx, %{"action" => "update", "name" => name} = args) do
    type = type_of_name(name)

    rewrite = fn bytes ->
      with {:ok, agent} <- AquaAgent.parse(name, bytes),
           :ok <- check_expected_digest(agent, args["expected_digest"]),
           agent = apply_updates(agent, args),
           {:ok, policy} <- patched_policy(agent.tool_policy, args["tool_policy_patch"], type) do
        {:ok, AquaAgent.serialize(%{agent | tool_policy: policy})}
      end
    end

    with :ok <- validate_name(name),
         :ok <- one_policy_argument(args),
         :ok <- validate_tool_policy(args["tool_policy"], type),
         :ok <- validate_patch(args["tool_policy_patch"]),
         :ok <-
           Arca.Overlay.update(Sanctum.Context.actor(ctx), AquaPath.agent_file(name), rewrite) do
      resync_index(ctx)
      {:ok, %{updated: name}}
    else
      {:error, :not_found} ->
        {:error, {:not_found, "Soul or role", name}}

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
  # A shipped role, edited or not, cannot be deleted (a reset restores
  # it) — disabling is the closet-removal verb. A member-created role
  # deletes outright. The soul takes the same verb and refuses with its
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
          {:error, {:not_found, "Soul or role", name}}

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
  # With a name, one role's (or the soul's) edited copy is restored;
  # without, every edited copy of a shipped unit.

  def handle(%Context{} = ctx, %{"action" => "reset", "name" => name}) when is_binary(name) do
    with :ok <- validate_name(name) do
      restore_unit(ctx, AquaPath.agent_file(name), "Soul or role", name)
    end
  end

  def handle(%Context{} = ctx, %{"action" => "reset"} = args) do
    case Compendium.AquaTemplate.reset(ctx, all: args["all"] == true) do
      {:ok, %{reverted: reverted, kept: kept}} ->
        resync_index(ctx)
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
        Logger.error("[AquaTool] aqua.skill_list failed: #{inspect(reason)}")
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

  def handle(_ctx, %{"action" => "skill_get"}) do
    {:error, {:invalid_argument, "Missing required argument: name"}}
  end

  # A scroll is a dir unit with `SKILL.md` as its sentinel. Creating one
  # lands the manifest through the overlay's unit commit — sentinel last,
  # rollback on failure — so a half-written scroll never reads as one. The
  # name is taken if the union holds it, shipped or the estate's own, and
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

  def handle(_ctx, %{"action" => "skill_create"}) do
    {:error, {:invalid_argument, "Missing required argument: name"}}
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

  def handle(_ctx, %{"action" => "skill_update"}) do
    {:error, {:invalid_argument, "Missing required argument: name"}}
  end

  # Same disposition as an agent: a shipped scroll is restored by a reset,
  # never deleted; the estate's own goes.
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

        {:error, reason} ->
          Logger.error("[AquaTool] aqua.skill_delete #{name} failed: #{inspect(reason)}")
          {:error, {:unavailable, "Storage"}}
      end
    end
  end

  def handle(_ctx, %{"action" => "skill_delete"}) do
    {:error, {:invalid_argument, "Missing required argument: name"}}
  end

  # --- skill_reset ---

  def handle(%Context{} = ctx, %{"action" => "skill_reset", "name" => name}) do
    with :ok <- validate_name(name) do
      restore_unit(ctx, AquaPath.skill_dir(name), "Scroll", name)
    end
  end

  def handle(_ctx, %{"action" => "skill_reset"}) do
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
    if Cyfr.Ops.Error.reason?(reason) do
      {:error, reason}
    else
      Logger.error("[AquaTool] #{where} failed: #{inspect(reason)}")
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
        "Role '#{name}' ships with the server and cannot be deleted — " <>
          "disable it instead (update name=#{name} disabled=true)"
  end

  # The tree changed; the derived index follows it. Never the write's
  # failure: an index that lags is re-synced by the next write or sync.
  # One unit back to what ships; the estate's own work refuses in words.
  defp restore_unit(ctx, unit, noun, name) do
    case Compendium.AquaTemplate.restore(ctx, unit) do
      :ok ->
        resync_index(ctx)
        {:ok, %{restored: name}}

      {:error, :not_a_copy} ->
        {:error,
         {:invalid_argument,
          "#{noun} '#{name}' is this estate's own and has no shipped version to restore"}}

      {:error, :not_found} ->
        {:error, {:not_found, noun, name}}

      {:error, reason} ->
        Logger.error("[AquaTool] aqua restore #{name} failed: #{inspect(reason)}")
        {:error, {:unavailable, "Storage"}}
    end
  end

  defp resync_index(ctx) do
    case Compendium.AgentIndex.sync(ctx) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("[AquaTool] agent index not synced: #{inspect(reason)}")
    end
  end

  defp create_role(ctx, name, args) do
    role = %{
      name: name,
      title: Map.get(args, "title", name),
      description: Map.get(args, "description", ""),
      disabled: false,
      catalyst_ref: args["catalyst_ref"],
      model: args["model"],
      tool_policy: args["tool_policy"] || %{},
      prompt: Map.get(args, "content", "")
    }

    # A role is a file unit: the one atomic put IS the unit commit — no
    # sentinel, no rollback needed, the overlay's file CoW applies. It
    # goes through the commit for `if_absent:` alone: the union answers
    # for shipped and member-created roles alike, and asking it while the
    # commit holds the unit's draft is what keeps two creators of one
    # name from both passing a probe.
    bytes = AquaAgent.serialize(role)

    case Arca.Overlay.commit_unit(
           Sanctum.Context.actor(ctx),
           AquaPath.role_file(name),
           {:files, [{[], bytes}]},
           cap: {:checked, byte_size(bytes)},
           if_absent: true
         ) do
      {:ok, _written} ->
        answer = Map.merge(%{created: name, type: AquaAgent.role_type()}, clone_leave(ctx, name))
        resync_index(ctx)
        {:ok, answer}

      {:error, :exists} ->
        {:error, {:invalid_argument, "Role '#{name}' already exists"}}

      {:error, {:limit_reached, _, _} = reason} ->
        {:error, reason}

      # The unit's row is committed and only the move of its bytes did
      # not finish, so the role IS published: an index that does not name
      # a published role is a role the runtime never offers. The refusal
      # still says the bytes are not all served, and the storage sweep's
      # repair finishes the move.
      {:error, {:finish_failed, _}} = published ->
        resync_index(ctx)
        published

      # The store could not say whether the commit landed. The resync
      # reads the tree, so it is right either way.
      {:error, :unavailable} = unknown ->
        resync_index(ctx)
        unknown

      {:error, reason} ->
        passthrough_or_unavailable(reason, "aqua.create #{name}")
    end
  end

  # A role no glob on the soul names is a file the runtime never offers,
  # so the soul's leave to clone into the new role is given in the same
  # act as the role — one `<name>.*` key on its allowlist. The role stands
  # either way; an estate with no soul, or a soul write that fails, is
  # said in the answer (`cloneable: false` and why), never hidden.
  defp clone_leave(ctx, name) do
    soul = AquaPath.soul_name()
    glob = AquaAgent.clone_glob(name)

    rewrite = fn bytes ->
      with {:ok, agent} <- AquaAgent.parse(soul, bytes) do
        policy = Map.put(agent.tool_policy, glob, "auto")
        {:ok, AquaAgent.serialize(%{agent | tool_policy: policy})}
      end
    end

    case Arca.Overlay.update(Sanctum.Context.actor(ctx), AquaPath.agent_file(soul), rewrite) do
      :ok ->
        %{cloneable: true}

      {:error, :not_found} ->
        %{cloneable: false, note: "There is no soul here to clone into it."}

      {:error, reason} ->
        Logger.warning("[AquaTool] aqua.create #{name}: soul glob failed: #{inspect(reason)}")

        %{
          cloneable: false,
          note:
            "The soul was not given leave to clone into it: " <>
              (Cyfr.Ops.Error.render(reason) || "the write failed")
        }
    end
  end

  @doc """
  The digest of a prompt as `get` answers it in `content_digest`, and as
  `update` compares an `expected_digest` against — so an editor can say
  which version it edited.
  """
  @spec content_digest(String.t()) :: String.t()
  def content_digest(content) when is_binary(content), do: Cyfr.Digest.sha256_hex(content)

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

  defp one_policy_argument(%{"tool_policy" => policy, "tool_policy_patch" => patch})
       when not is_nil(policy) and not is_nil(patch),
       do: {:error, {:invalid_argument, "Give tool_policy or tool_policy_patch, not both"}}

  defp one_policy_argument(_args), do: :ok

  # The patch's own shape is checked at the door; what it makes of the
  # policy is checked inside the rewrite, where the policy is known.
  defp validate_patch(nil), do: :ok

  defp validate_patch(patch) when is_map(patch) do
    Enum.find_value(patch, :ok, fn
      {key, value} when not is_binary(key) or value not in ["ask", "auto", nil] ->
        {:error,
         {:invalid_argument, "tool_policy_patch: #{inspect(key)} must be ask, auto or null"}}

      _ ->
        nil
    end)
  end

  defp validate_patch(_patch),
    do: {:error, {:invalid_argument, "tool_policy_patch must be an object"}}

  defp patched_policy(policy, nil, _type), do: {:ok, policy}

  defp patched_policy(policy, patch, type) do
    merged =
      Enum.reduce(patch, policy, fn
        {key, nil}, acc -> Map.delete(acc, key)
        {key, mode}, acc -> Map.put(acc, key, mode)
      end)

    with :ok <- validate_tool_policy(merged, type), do: {:ok, merged}
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

  # Two rules at this door. The grammar is `Compendium.AquaAgent
  # .check_tool_policy/1` — the same rule the file parser applies, so
  # nothing this door admits can fail to parse back. The meaning is
  # `Aqua.Policy.check_authored/2` — what a person may WRITE: no automatic
  # destructive or external action on any agent, no `ask` on a role (a
  # cloned role has no card to raise), no UI event held at ask. The parser
  # keeps grammar only, so a hand-edited file still loads and the runtime
  # ceiling (`Aqua.ToolGrants.effective/2`) demotes what this door would
  # have refused. An absent argument leaves the policy alone
  # (`apply_updates/2`).
  defp validate_tool_policy(nil, _type), do: :ok

  defp validate_tool_policy(policy, type) do
    with :ok <- check_grammar(policy),
         :ok <- Aqua.Policy.check_auto_only(policy),
         :ok <- Aqua.Policy.check_authored(policy, type) do
      :ok
    else
      {:error, reason} when is_binary(reason) -> {:error, {:invalid_argument, reason}}
      {:error, reason} -> {:error, {:invalid_argument, tool_policy_message(reason)}}
    end
  end

  defp check_grammar(policy), do: AquaAgent.check_tool_policy(policy)

  defp type_of_name(name),
    do: if(AquaPath.soul?(name), do: AquaAgent.soul_type(), else: AquaAgent.role_type())

  defp tool_policy_message({:tool_policy_invalid_value, key, value}),
    do:
      "Invalid tool_policy value #{inspect(value)} for #{inspect(key)} — use \"ask\" or \"auto\""

  defp tool_policy_message({:tool_policy_invalid_key, key}),
    do:
      "Invalid tool_policy key #{inspect(key)} — use \"tool.action\", \"tool.*\", or \"native_search\""

  defp tool_policy_message(:tool_policy_not_a_map), do: "tool_policy must be an object"
end
