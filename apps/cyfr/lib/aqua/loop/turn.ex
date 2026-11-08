# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Turn do
  @moduledoc """
  What a loop runs, rebuilt from rows: the turn and its thread, the
  agent as the turn pinned it — the revision bytes, resolved as the agent
  runs (a crew member under the soul's policy,
  `Compendium.resolve_agent/3`), whose capability digest must equal the
  one the turn started under — the roster, the effective policy composed
  with the standing rows and narrowed to the tools a crew request named
  (`options["tools"]`), the resolved model catalyst with its capabilities
  and the request size its consent caps it at (`request_cap`), the brain
  options — the agent file's own, over which a crew request's
  (`options["brain_options"]`) set theirs — the system prompt and the
  sources it read, the tool surface (with the accounts its launches may name,
  read once here for every request the spec makes,
  `Aqua.Hands.launch_accounts/1`), the room excerpt the sender attached,
  the deadline the authority allows, never under one answer of its brain
  (`brain_timeout_ms/1`), and the admission decision the
  turn's root execution was started under (`call_id`), which every call
  the turn makes names as its parent call.

  Every model round of a spec runs on the model it resolved, compaction
  included: nothing chooses another model for a step.
  """

  require Logger

  alias Aqua.Loop.Request
  alias Aqua.Tape
  alias Prima.Authority
  alias Sanctum.Context

  @default_deadline_ms 15 * 60 * 1000
  @probe_timeout_ms 60_000

  @type t :: %__MODULE__{}

  defstruct [
    :ctx,
    :guest,
    :turn,
    :call_id,
    :thread,
    :agent,
    :roster,
    :policy,
    :authority,
    :catalyst,
    :model,
    :capabilities,
    :request_cap,
    :system,
    :tools,
    :deadline_ms,
    :approval_ttl_s,
    :options,
    :brain_options,
    :narrowed,
    :excerpt,
    :attachments,
    soul?: true,
    sources: []
  ]

  @doc """
  Build the spec for `turn` as `ctx` (the actor's external-plane context).
  `opts`: `:authority` (the turn's pinned authority, required),
  `:excerpt?` (read the room excerpt the turn's options name).

  Refuses an agent that names no model (`:no_model`), a catalyst the
  athanor does not hold or that does not speak `model/chat@1`, and a
  model its catalyst cannot describe (`Aqua.Models.capabilities/5`; a
  typed refusal is `{:model_refused, catalyst, error}`, and a catalyst
  whose consent lacks its key `{:setup_required, catalyst}`).
  """
  @spec build(Context.t(), Tape.turn(), keyword()) :: {:ok, t()} | {:error, term()}
  def build(%Context{} = ctx, turn, opts) do
    authority = Keyword.fetch!(opts, :authority)

    with {:ok, thread} <- Tape.thread(ctx, turn.thread_id),
         {:ok, roster} <- Aqua.AgentConfig.roster(ctx),
         {:ok, agent} <- agent(ctx, turn),
         soul? = Prima.AgentRef.soul?(agent["name"]),
         options = decode(turn.options),
         brain_options = Map.merge(agent["options"] || %{}, options["brain_options"] || %{}),
         {:ok, grants} <-
           Aqua.ToolGrants.for_agents(ctx, turn.thread_id, [agent["name"]]),
         policy =
           agent["tool_policy"]
           |> Aqua.ToolGrants.resolve(Map.fetch!(grants, agent["name"]))
           |> narrowed(options["tools"]),
         {:ok, catalyst, model} <- model(ctx, turn, agent),
         {:ok, capabilities} <- capabilities(ctx, authority, catalyst, model, turn),
         :ok <- brain_options(brain_options, capabilities) do
      prompt =
        Aqua.Prompt.compose(ctx,
          agent: agent,
          authority: authority,
          crew: crew(ctx, roster, policy, soul?),
          requests: requests(ctx, thread)
        )

      spec = %__MODULE__{
        ctx: ctx,
        guest: Context.enter_guest(ctx),
        turn: turn,
        call_id: root_call_id(ctx, turn),
        thread: thread,
        agent: agent,
        roster: roster,
        policy: policy,
        authority: authority,
        catalyst: catalyst,
        model: model,
        capabilities: capabilities,
        request_cap: request_cap(authority, catalyst),
        system: prompt.text,
        sources: prompt.sources,
        tools:
          Request.tool_definitions(policy,
            external: external_tools(policy),
            accounts: launch_accounts(ctx, policy)
          ),
        deadline_ms: deadline_ms(authority, brain_timeout_ms(authority, catalyst)),
        approval_ttl_s: Aqua.Approvals.ttl_seconds(ctx),
        options: options,
        brain_options: brain_options,
        narrowed: options["tools"],
        excerpt: if(Keyword.get(opts, :excerpt?, true), do: excerpt(ctx, options), else: nil),
        attachments: attachments(ctx, turn, capabilities.media_types),
        soul?: soul?
      }

      {:ok, spec}
    end
  end

  # The admission the turn's root execution was started under, read off
  # its row once: the parent call of the calls the turn makes. It is audit
  # correlation, so a row that cannot be read names none.
  defp root_call_id(ctx, %{root_execution_id: id}) when is_binary(id) do
    case Opus.get(ctx, id) do
      {:ok, %{call_id: call_id}} -> call_id
      _ -> nil
    end
  end

  defp root_call_id(_ctx, _turn), do: nil

  @doc "The turn row replaced, everything else kept."
  @spec with_turn(t(), Tape.turn()) :: t()
  def with_turn(%__MODULE__{} = spec, turn), do: %{spec | turn: turn}

  # The options the agent's file and a crew request set must be ones the
  # brain declares, each of its kind; a turn that sets another is refused
  # before it sends anything.
  defp brain_options(options, _capabilities) when options == %{}, do: :ok

  defp brain_options(options, capabilities) do
    case Prima.Model.check_chat_request(
           %{"options" => options},
           Map.get(capabilities, :options) || []
         ) do
      :ok -> :ok
      {:error, {:invalid, member}} -> {:error, "the brain does not take #{member} as it was set"}
    end
  end

  # A crew request narrows the job to the tools it names: a key stays when
  # its tool or its `tool.action` is named, so the narrowing only takes
  # away from what the agent's policy and the ceiling already allow.
  defp narrowed(policy, [_ | _] = names) do
    named = MapSet.new(names)

    Map.filter(policy, fn {key, _mode} ->
      tool = key |> String.split(".", parts: 2) |> hd()
      MapSet.member?(named, key) or MapSet.member?(named, tool)
    end)
  end

  defp narrowed(policy, _all), do: policy

  # The crew index, listed in the soul's prompt when its policy offers
  # `crew.ask`; only the soul hands a job on (`Aqua.Runner.Admission`). An
  # index that cannot be read lists no crew this turn, and says so in the
  # log.
  defp crew(ctx, roster, policy, true = _soul?) do
    with true <- Map.get(policy, "crew.ask") in ["auto", "ask"],
         {:ok, index} <- Aqua.Crew.index(ctx, roster) do
      index
    else
      false ->
        []

      {:error, reason} ->
        Logger.warning("[Aqua.Loop.Turn] the crew index could not be read: #{inspect(reason)}")
        []
    end
  end

  defp crew(_ctx, _roster, _policy, false = _soul?), do: []

  # The room's requests still waiting on a reply, which the prompt lists
  # with their age; a child thread holds none.
  defp requests(ctx, %{kind: "own", id: thread_id}) do
    case Tape.pending_requests(ctx, thread_id) do
      rows when is_list(rows) -> rows
      {:error, _} -> []
    end
  end

  defp requests(_ctx, _thread), do: []

  # ---------------------------------------------------------------------------
  # The agent
  # ---------------------------------------------------------------------------

  # A turn runs the agent it pinned from the revision bytes, parsed, with
  # their capability digest checked against the pin. Every start pins
  # both, so a turn that pins neither, or only one, is refused; a revision
  # the tree no longer holds is refused too, never replaced.
  # A crew member's bytes resolve under the soul's policy as it stands, so
  # a soul whose policy moved since the turn started moves the digest and
  # refuses the turn, as an edit of the member's own file does.
  defp agent(ctx, %{agent_revision_digest: revision, agent_capability_digest: capability} = turn)
       when is_binary(revision) and is_binary(capability) do
    case Tape.agent_revision(ctx, turn) do
      {:ok, bytes} -> pinned_agent(ctx, turn, bytes)
      {:error, reason} -> {:error, {:agent_unavailable, reason}}
    end
  end

  defp agent(_ctx, _turn), do: {:error, :no_pin}

  defp pinned_agent(ctx, turn, bytes) do
    with {:ok, parsed} <- Compendium.resolve_agent(ctx, turn.agent, bytes),
         {:ok, digest} <- Compendium.agent_capability_digest(parsed) do
      if digest == turn.agent_capability_digest,
        do: {:ok, agent_map(parsed)},
        else: {:error, :agent_changed}
    end
  end

  defp agent_map(%{name: name} = parsed) do
    %{
      "name" => name,
      "title" => parsed.title,
      "description" => parsed.description,
      "avoid" => parsed.avoid,
      "prompt" => parsed.prompt,
      "tool_policy" => parsed.tool_policy,
      "catalyst_ref" => parsed.catalyst_ref,
      "model" => parsed.model,
      "options" => parsed.options
    }
  end

  # ---------------------------------------------------------------------------
  # The model
  # ---------------------------------------------------------------------------

  # The catalyst release a turn runs on: once its row pins one, exactly
  # that release; before, the agent's catalyst resolved against the working
  # athanor's listing. It must be installed and speak `model/chat@1`. A
  # switch of the agent's catalyst reaches the next turn; what a turn
  # already sent to its provider stays that provider's.
  defp model(ctx, turn, agent) do
    listing =
      case Aqua.AgentConfig.catalyst_listing(ctx) do
        {:ok, listing} -> listing
        {:error, _} -> []
      end

    with {:ok, catalyst, model} <- catalyst(listing, turn, agent),
         :ok <- speaks_chat(listing, catalyst) do
      if is_binary(model), do: {:ok, catalyst, model}, else: {:error, :no_model}
    end
  end

  defp catalyst(listing, %{catalyst_ref: pinned} = turn, agent) when is_binary(pinned) do
    if Enum.any?(listing, &(&1["component_ref"] == pinned)),
      do: {:ok, pinned, turn.model || agent["model"]},
      else: {:error, {:catalyst_not_in_athanor, pinned}}
  end

  defp catalyst(listing, turn, agent) do
    case Aqua.AgentConfig.resolve_catalyst(listing, agent["catalyst_ref"]) do
      {:ok, catalyst} -> {:ok, catalyst, turn.model || agent["model"]}
      {:error, _} -> {:error, {:catalyst_not_in_athanor, agent["catalyst_ref"]}}
    end
  end

  # The request size the consent graph caps the catalyst at, or nil. Read
  # by name, without the version: the spec carries a versioned ref because
  # that is what resolved, but the graph keys every node by name
  # (`Opus.Admission` steps by name), so a versioned key finds nothing and
  # a cap of nil is a check that never fires.
  defp request_cap(authority, catalyst) do
    with {:ok, name_ref} <- Prima.ComponentRef.to_name_ref(catalyst),
         {:ok, %Prima.Limits{max_request_size: cap}} <-
           Prima.Authority.node_limits(authority, name_ref) do
      cap
    else
      _ -> nil
    end
  end

  @doc """
  How long the brain the spec runs on is consented to take over one
  answer, in milliseconds: the `limits.timeout` of its catalyst's node in
  the turn's authority, read by name as `request_cap` is. It is the
  deadline admission gives a model call and the worker service enforces
  (`Opus.Admission`), so it is how long the loop waits for the answer
  (`Aqua.Loop`), and the turn's own deadline is never under it. Nil when
  the graph holds no such node or its timeout does not parse: admission
  refuses such a call before anything runs.
  """
  @spec brain_timeout_ms(t()) :: pos_integer() | nil
  def brain_timeout_ms(%__MODULE__{authority: authority, catalyst: catalyst}),
    do: brain_timeout_ms(authority, catalyst)

  defp brain_timeout_ms(authority, catalyst) do
    with {:ok, name_ref} <- Prima.ComponentRef.to_name_ref(catalyst),
         {:ok, limits} <- Prima.Authority.node_limits(authority, name_ref),
         {:ok, ms} when ms > 0 <- Prima.Limits.timeout_ms(limits) do
      ms
    else
      _ -> nil
    end
  end

  defp speaks_chat(listing, catalyst) do
    row = Enum.find(listing, &(&1["component_ref"] == catalyst)) || %{}

    if Prima.Model.speaks_chat?(row["manifest"]),
      do: :ok,
      else: {:error, {:catalyst_not_chat, catalyst}}
  end

  defp capabilities(ctx, authority, catalyst, model, turn) do
    case Aqua.Models.capabilities(ctx, catalyst, model, authority.consent_id,
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
          Opus.run_child(authority, catalyst, nil, input,
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

  # The apps a launch may name an account of, read once for the spec and
  # kept for every request it makes: only when the agent may launch at
  # all. A crew member holds the soul's policy, so it may as the soul may.
  defp launch_accounts(ctx, policy) do
    if Map.get(policy, "execution.run") in ["auto", "ask"],
      do: Aqua.Hands.launch_accounts(ctx),
      else: nil
  end

  # An external server's tools the policy names (`server:tool`), as the
  # catalog knows them.
  defp external_tools(policy) do
    for {key, mode} <- policy,
        mode in ["auto", "ask"],
        String.contains?(key, ":"),
        {:ok, definition} <- [Sanctum.Catalog.get_tool(key)] do
      %{
        name: key,
        description: definition["description"],
        input_schema: definition["inputSchema"]
      }
    end
  end

  # The turn's active time: the agent's own consented timeout (the node
  # the authority's cursor stands on, `Authority.limits/1`), the default
  # when it names none, and never under one answer of its brain, so a
  # brain consented longer than its agent is not cut off by the agent's.
  defp deadline_ms(%Authority{} = authority, brain_ms) do
    own =
      case Prima.Limits.timeout_ms(Authority.limits(authority)) do
        {:ok, ms} when ms > 0 -> ms
        _ -> @default_deadline_ms
      end

    max(own, brain_ms || 0)
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
  def current_policy(%__MODULE__{ctx: ctx, turn: turn, agent: agent, options: options}) do
    name = agent["name"]

    with {:ok, grants} <- Aqua.ToolGrants.for_agents(ctx, turn.thread_id, [name]) do
      {:ok,
       agent["tool_policy"]
       |> Aqua.ToolGrants.resolve(Map.fetch!(grants, name))
       |> narrowed((options || %{})["tools"])}
    end
  end

  defp decode(nil), do: %{}

  defp decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp excerpt(ctx, %{"room" => %{"shared_thread_id" => thread_id} = room})
       when is_binary(thread_id) do
    case Aqua.RoomExcerpt.read(ctx, %{shared_thread_id: thread_id, title: room["title"]}) do
      {:ok, text} -> text
      {:error, _} -> nil
    end
  end

  defp excerpt(_ctx, _options), do: nil

  # The initiating message's attachments as blocks the brain takes. A
  # delivered request's are the request's own, stored under its row in its
  # room.
  defp attachments(ctx, %{message_id: message_id, thread_id: thread_id}, media_types)
       when is_binary(message_id) do
    case Tape.message(ctx, message_id) do
      {:ok, row} ->
        {thread_id, refs} = stored_under(row, thread_id, Aqua.Attachments.attachments_of([row]))

        ctx
        |> Aqua.Attachments.load(thread_id, refs)
        |> Enum.map(&attachment_block(&1, media_types))

      _ ->
        []
    end
  end

  defp attachments(_ctx, _turn, _media_types), do: []

  # A file goes inline, as the image or document block its media type
  # makes, only when the brain declares that type (its capabilities'
  # `media_types`); a text file it does not take goes as a text block
  # under its name; any other file is named as attached and not readable
  # by this brain. No request carries a block the brain refuses.
  defp attachment_block(%{"media_type" => media, "data" => data, "filename" => name}, types) do
    cond do
      media in types ->
        %{
          "type" => if(String.starts_with?(media, "image/"), do: "image", else: "document"),
          "media_type" => media,
          "data" => data,
          "filename" => name
        }

      text = text(media, data) ->
        %{"type" => "text", "text" => "The attached file #{name}:\n\n" <> text}

      true ->
        %{
          "type" => "text",
          "text" => "The file #{name} (#{media}) is attached, and this brain cannot read it."
        }
    end
  end

  # The file's text, when its media type is not opaque bytes and its bytes
  # are UTF-8; nil otherwise.
  defp text(media, data) do
    with false <- Prima.MediaType.binary_mime?(media || Prima.MediaType.binary()),
         {:ok, bytes} <- Base.decode64(data),
         true <- String.valid?(bytes) do
      bytes
    else
      _opaque -> nil
    end
  end

  defp stored_under(row, thread_id, refs) do
    case Tape.payload(row) do
      %{"request_id" => request_id, "from_thread" => room}
      when is_binary(request_id) and is_binary(room) ->
        {room, Enum.map(refs, &%{&1 | message_id: request_id})}

      _ ->
        {thread_id, refs}
    end
  end
end
