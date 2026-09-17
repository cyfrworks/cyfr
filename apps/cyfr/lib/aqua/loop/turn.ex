# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Turn do
  @moduledoc """
  What a loop runs, rebuilt from rows: the turn and its thread, the
  agent as the turn pinned it — the revision bytes, whose capability
  digest must equal the one the turn started under — the roster and the
  roles the soul may clone into, the effective policy composed with the
  standing rows, the resolved model catalyst with its capabilities, the
  system prompt, the tool surface, the room excerpt the sender attached,
  and the deadline the authority allows.

  A clone's spec is built the same way from the role's definition, under
  the parent's authority and catalyst.
  """

  alias Aqua.Loop.Request
  alias Aqua.Tape
  alias Cyfr.Authority
  alias Sanctum.Context

  @default_deadline_ms 15 * 60 * 1000
  @probe_timeout_ms 60_000

  @type t :: %__MODULE__{}

  defstruct [
    :ctx,
    :guest,
    :turn,
    :thread,
    :agent,
    :roster,
    :roles,
    :policy,
    :authority,
    :catalyst,
    :model,
    :capabilities,
    :system,
    :tools,
    :deadline_ms,
    :approval_ttl_s,
    :options,
    :excerpt,
    :attachments,
    soul?: true,
    several_people?: false
  ]

  @doc """
  Build the spec for `turn` as `ctx` (the actor's external-plane context).
  `opts`: `:authority` (the turn's pinned authority, required),
  `:catalyst` and `:model` (a clone's fallbacks, the parent's),
  `:excerpt?` (read the room excerpt the turn's options name).

  Refuses an agent that names no model (`:no_model`), a catalyst the
  estate does not hold or that does not speak `model/chat@1`, and a
  model its catalyst cannot describe (`Cyfr.Models.capabilities/5`; a
  typed refusal is `{:model_refused, catalyst, error}`, and a catalyst
  whose consent lacks its key `{:setup_required, catalyst}`).
  """
  @spec build(Context.t(), Tape.turn(), keyword()) :: {:ok, t()} | {:error, term()}
  def build(%Context{} = ctx, turn, opts) do
    authority = Keyword.fetch!(opts, :authority)

    with {:ok, thread} <- Tape.thread(ctx, turn.thread_id),
         {:ok, roster} <- Aqua.AgentConfig.roster(ctx),
         {:ok, agent} <- agent(ctx, turn, roster),
         soul? = Compendium.AgentSource.soul?(agent["name"]),
         roles = if(soul?, do: roles(roster), else: []),
         {:ok, grants} <-
           Aqua.ToolGrants.for_agents(ctx, turn.thread_id, [agent["name"]]),
         policy =
           Aqua.ToolGrants.resolve(agent["tool_policy"] || %{}, grants[agent["name"]] || []),
         {:ok, catalyst, model} <- model(ctx, turn, agent, opts),
         {:ok, capabilities} <- capabilities(ctx, authority, catalyst, model, turn) do
      options = decode(turn.options)
      several? = not Sanctum.Tenancy.Members.solo?(Context.athanor!(ctx))

      spec = %__MODULE__{
        ctx: ctx,
        guest: Context.enter_guest(ctx),
        turn: turn,
        thread: thread,
        agent: agent,
        roster: roster,
        roles: roles,
        policy: policy,
        authority: authority,
        catalyst: catalyst,
        model: model,
        capabilities: capabilities,
        system:
          Aqua.Prompt.compose(ctx,
            agent: agent,
            authority: authority,
            several_people?: several?
          ),
        tools:
          Request.tool_definitions(policy,
            roles: roles,
            external: external_tools(policy),
            soul?: soul?
          ),
        deadline_ms: deadline_ms(authority),
        approval_ttl_s: Aqua.Approvals.ttl_seconds(ctx),
        options: options,
        excerpt: if(Keyword.get(opts, :excerpt?, true), do: excerpt(ctx, options), else: nil),
        attachments: attachments(ctx, turn),
        soul?: soul?,
        several_people?: several?
      }

      {:ok, spec}
    end
  end

  @doc "The turn row replaced, everything else kept."
  @spec with_turn(t(), Tape.turn()) :: t()
  def with_turn(%__MODULE__{} = spec, turn), do: %{spec | turn: turn}

  @doc "The roster entries the soul may clone into, as the request offers them."
  @spec role_entries(t()) :: [map()]
  def role_entries(%__MODULE__{roles: roles}), do: roles

  @doc "The role names the soul may clone into."
  @spec role_names(t()) :: [String.t()]
  def role_names(%__MODULE__{roles: roles}), do: Enum.map(roles, & &1["name"])

  @doc "One role's definition from the roster, else `{:error, :no_such_role}`."
  @spec role(t(), String.t()) :: {:ok, map()} | {:error, :no_such_role}
  def role(%__MODULE__{roster: roster}, name) do
    case Enum.find(roster, &(&1["name"] == name and &1["type"] == role_type())) do
      nil -> {:error, :no_such_role}
      entry -> {:ok, agent_map(entry)}
    end
  end

  # ---------------------------------------------------------------------------
  # The agent
  # ---------------------------------------------------------------------------

  # A turn runs the agent it pinned — the soul or a clone's role — from the
  # revision bytes, parsed, with their capability digest checked against
  # the pin. A turn without a pin (a revision the tree no longer holds is
  # refused, never replaced) takes the roster's current entry.
  defp agent(ctx, turn, roster) do
    case Tape.agent_revision(ctx, turn) do
      {:ok, bytes} -> pinned_agent(turn, bytes)
      {:error, :no_revision} -> roster_agent(turn, roster)
      {:error, reason} -> {:error, {:agent_unavailable, reason}}
    end
  end

  defp pinned_agent(turn, bytes) do
    with {:ok, parsed} <- Compendium.AquaAgent.parse(turn.agent, bytes),
         {:ok, digest} <- Compendium.AquaAgent.capability_digest(parsed) do
      if is_nil(turn.agent_capability_digest) or digest == turn.agent_capability_digest,
        do: {:ok, agent_map(parsed)},
        else: {:error, :agent_changed}
    end
  end

  defp roster_agent(turn, roster) do
    case Enum.find(roster, &(&1["name"] == turn.agent)) do
      nil -> {:error, :no_agent}
      entry -> {:ok, agent_map(entry)}
    end
  end

  # One shape for a parsed revision and a roster entry.
  defp agent_map(%{name: name} = parsed) do
    %{
      "name" => name,
      "title" => parsed.title || name,
      "description" => parsed.description || "",
      "prompt" => parsed.prompt || "",
      "tool_policy" => parsed.tool_policy || %{},
      "catalyst_ref" => parsed.catalyst_ref,
      "model" => parsed.model
    }
  end

  defp agent_map(%{"name" => name} = entry) do
    %{
      "name" => name,
      "title" => entry["title"] || name,
      "description" => entry["description"] || "",
      "prompt" => entry["content"] || entry["prompt"] || "",
      "tool_policy" => entry["tool_policy"] || %{},
      "catalyst_ref" => entry["catalyst_ref"],
      "model" => entry["model"]
    }
  end

  defp roles(roster) do
    role_type = role_type()

    for %{"type" => ^role_type, "name" => name} = entry <- roster do
      %{
        "name" => name,
        "title" => entry["title"] || name,
        "description" => entry["description"] || ""
      }
    end
  end

  defp role_type, do: Compendium.AquaAgent.role_type()

  # ---------------------------------------------------------------------------
  # The model
  # ---------------------------------------------------------------------------

  # The catalyst release a turn runs on: once its row pins one, exactly
  # that release; before, the agent's catalyst resolved against the working
  # estate's listing, a clone falling back to the parent's. It must be
  # installed and speak `model/chat@1`.
  defp model(ctx, turn, agent, opts) do
    listing =
      case Aqua.AgentConfig.catalyst_listing(ctx) do
        {:ok, listing} -> listing
        {:error, _} -> []
      end

    with {:ok, catalyst, model} <- catalyst(listing, turn, agent, opts),
         :ok <- speaks_chat(listing, catalyst) do
      if is_binary(model), do: {:ok, catalyst, model}, else: {:error, :no_model}
    end
  end

  defp catalyst(listing, %{catalyst_ref: pinned} = turn, agent, _opts) when is_binary(pinned) do
    if Enum.any?(listing, &(&1["component_ref"] == pinned)),
      do: {:ok, pinned, turn.model || agent["model"]},
      else: {:error, {:catalyst_not_in_estate, pinned}}
  end

  defp catalyst(listing, turn, agent, opts) do
    model = turn.model || agent["model"]

    case {Aqua.AgentConfig.resolve_catalyst(listing, agent["catalyst_ref"]),
          Keyword.get(opts, :catalyst)} do
      {{:ok, catalyst}, _} ->
        {:ok, catalyst, model}

      {{:error, _}, parent} when is_binary(parent) ->
        {:ok, parent, model || Keyword.get(opts, :model)}

      {{:error, _}, _} ->
        {:error, {:catalyst_not_in_estate, agent["catalyst_ref"]}}
    end
  end

  defp speaks_chat(listing, catalyst) do
    row = Enum.find(listing, &(&1["component_ref"] == catalyst)) || %{}

    if Cyfr.Models.speaks_chat?(row["manifest"]),
      do: :ok,
      else: {:error, {:catalyst_not_chat, catalyst}}
  end

  defp capabilities(ctx, authority, catalyst, model, turn) do
    case Cyfr.Models.capabilities(ctx, catalyst, model, authority.consent_id,
           run: capability_probe(ctx, authority, catalyst, turn)
         ) do
      {:ok, capabilities} -> {:ok, capabilities}
      {:error, {:model_refused, error}} -> {:error, {:model_refused, catalyst, error}}
      {:error, {:describe_failed, {:setup_required, _}}} -> {:error, {:setup_required, catalyst}}
      {:error, _} = error -> error
    end
  end

  # The catalyst's own answers about itself, run as a child of the turn
  # in a worker: the calling process holds the root, and a child slot
  # taken on it would displace the root's.
  defp capability_probe(ctx, authority, catalyst, turn) do
    guest = Context.enter_guest(ctx)

    fn input ->
      task =
        Aqua.Loop.Worker.async(fn ->
          Cyfr.Execution.run_child(authority, catalyst, nil, input,
            ctx: guest,
            parent_execution_id: turn.root_execution_id,
            root_execution_id: turn.root_execution_id,
            declared_needs: [],
            retention_class: "chat_step",
            envelope: true
          )
        end)

      case Aqua.Loop.Worker.yield(task, @probe_timeout_ms) || Aqua.Loop.Worker.shutdown(task) do
        {:ok, {:ok, %{output: output}}} -> {:ok, output}
        {:ok, {:ok, output}} -> {:ok, output}
        {:ok, {:error, _} = error} -> error
        _ -> {:error, :probe_failed}
      end
    end
  end

  # An external server's tools the policy names (`server:tool`), as the
  # catalog knows them.
  defp external_tools(policy) do
    for {key, mode} <- policy,
        mode in ["auto", "ask"],
        String.contains?(key, ":"),
        {:ok, definition} <- [Cyfr.Ops.Catalog.get_tool(key)] do
      %{
        name: key,
        description: definition["description"],
        input_schema: definition["inputSchema"]
      }
    end
  end

  defp deadline_ms(%Authority{} = authority) do
    case Cyfr.Limits.timeout_ms(Authority.limits(authority)) do
      {:ok, ms} when ms > 0 -> ms
      _ -> @default_deadline_ms
    end
  end

  # ---------------------------------------------------------------------------
  # What the sender attached
  # ---------------------------------------------------------------------------

  @doc """
  The agent's policy recomposed against the member's grants as they stand.

  `build/3`'s policy is a snapshot. A member withdrawing a standing grant
  mid-turn writes the rows and refreshes the runner; nothing rebuilds the
  snapshot a running loop decides from, so a call that has not dispatched
  yet asks again. The authored half is the pinned agent definition and is
  never re-read here.
  """
  @spec current_policy(t()) :: {:ok, map()} | {:error, term()}
  def current_policy(%__MODULE__{ctx: ctx, turn: turn, agent: agent}) do
    name = agent["name"]

    with {:ok, grants} <- Aqua.ToolGrants.for_agents(ctx, turn.thread_id, [name]) do
      {:ok, Aqua.ToolGrants.resolve(agent["tool_policy"] || %{}, grants[name] || [])}
    end
  end

  defp decode(nil), do: %{}

  defp decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp decode(%{} = map), do: map

  defp excerpt(ctx, %{
         "room" => %{"athanor_id" => athanor_id, "thread_id" => thread_id} = room
       })
       when is_binary(athanor_id) and is_binary(thread_id) do
    case Aqua.RoomExcerpt.read(ctx, %{
           athanor_id: athanor_id,
           thread_id: thread_id,
           estate: room["estate"],
           title: room["title"]
         }) do
      {:ok, text} -> text
      {:error, _} -> nil
    end
  end

  defp excerpt(_ctx, _options), do: nil

  # The initiating message's attachments as typed blocks.
  defp attachments(ctx, %{message_id: message_id, thread_id: thread_id})
       when is_binary(message_id) do
    case Tape.message(ctx, message_id) do
      {:ok, row} ->
        refs = Aqua.Attachments.attachments_of([row])

        ctx
        |> Aqua.Attachments.load(thread_id, refs)
        |> Enum.map(fn %{"media_type" => media, "data" => data, "filename" => name} ->
          %{
            "type" =>
              if(String.starts_with?(media || "", "image/"), do: "image", else: "document"),
            "media_type" => media,
            "data" => data,
            "filename" => name
          }
        end)

      _ ->
        []
    end
  end

  defp attachments(_ctx, _turn), do: []
end
