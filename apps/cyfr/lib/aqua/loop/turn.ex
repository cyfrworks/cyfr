# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Turn do
  @moduledoc """
  What a loop runs, rebuilt from rows: the turn and its thread, the
  agent as the turn pinned it — the revision bytes, resolved as the agent
  runs (a crew member offered the soul's tools,
  `Compendium.resolve_agent/3`), whose capability digest must equal the
  one the turn started under — the roster, the member's mode and the set
  it is offered (`Aqua.Offered`) narrowed to the tools a crew request
  named (`options["tools"]`), the resolved model catalyst with its capabilities
  and the request size its consent caps it at (`request_cap`), the brain
  options — the agent file's own, over which a crew request's
  (`options["brain_options"]`) set theirs — the system prompt and the
  sources it read, the tool surface (with the accounts its launches may name,
  read once here for every request the spec makes,
  `Aqua.Hands.launch_accounts/1`), the room excerpt the sender attached,
  the deadline the authority allows, never under one answer of its brain
  (`deadline_ms/2`), and the admission decision the
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
  # A person's rooms, which hold a crew's waiting requests.
  @rooms Tape.room_kinds()
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
    # What the turn may call (`Aqua.Offered`) and the member's mode, which
    # decides what of it runs (`Aqua.Loop.Policy`).
    :offered,
    :mode,
    :authority,
    :catalyst,
    # The program row a program brain runs on, `%{row, epoch, name}`, or
    # nil for a catalyst's brain.
    :program,
    :model,
    :capabilities,
    :request_cap,
    :system,
    :tools,
    :deadline_ms,
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
  `:excerpt?` (read the room excerpt the turn's options name), and
  `:asks_model?`: false for a turn opened on a page's call, which asks no
  model, so its brain is not described and its capabilities are none
  (`Aqua.Models.none/0`).

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
         offered =
           agent["tools"]
           |> Aqua.Offered.resolve(Aqua.BrowserSetting.allowed?(ctx))
           |> narrowed(options["tools"]),
         {:ok, brain, model} <- model(ctx, turn, agent),
         {catalyst, program} = brain,
         asks? = Keyword.get(opts, :asks_model?, true) and program == nil,
         {:ok, capabilities} <- asked(asks?, ctx, authority, catalyst, model, turn),
         :ok <- if(asks?, do: brain_options(brain_options, capabilities), else: :ok) do
      prompt =
        Aqua.Prompt.compose(ctx,
          agent: agent,
          authority: authority,
          crew: crew(ctx, roster, offered, soul?),
          requests: requests(ctx, thread),
          where: Aqua.Prompt.where(ctx, thread)
        )

      spec = %__MODULE__{
        ctx: ctx,
        guest: Context.enter_guest(ctx),
        turn: turn,
        call_id: root_call_id(ctx, turn),
        thread: thread,
        agent: agent,
        roster: roster,
        offered: offered,
        # The mode the turn's row pinned at its start, from the same
        # snapshot whose capability digest the agent was just checked
        # against.
        mode: turn.agent_mode,
        authority: authority,
        catalyst: catalyst,
        program: program,
        model: model,
        capabilities: capabilities,
        request_cap: request_cap(authority, catalyst),
        system: prompt.text,
        sources: prompt.sources,
        tools:
          Request.tool_definitions(offered,
            external: external_tools(offered),
            accounts: launch_accounts(ctx, offered)
          ),
        deadline_ms: deadline_ms(authority, brain_timeout_ms(authority, catalyst)),
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
      {:ok, %{admitted: %{call_id: call_id}}} -> call_id
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
  # away from what the member is offered.
  defp narrowed(offered, [_ | _] = names) do
    named = MapSet.new(names)

    Map.filter(offered, fn {key, _offered} ->
      tool = key |> String.split(".", parts: 2) |> hd()
      MapSet.member?(named, key) or MapSet.member?(named, tool)
    end)
  end

  defp narrowed(offered, _all), do: offered

  # The crew index, listed in the soul's prompt when it is offered
  # `crew.ask`; only the soul hands a job on (`Aqua.Runner.Admission`). An
  # index that cannot be read lists no crew this turn, and says so in the
  # log.
  defp crew(ctx, roster, offered, true = _soul?) do
    with true <- Aqua.Offered.offered?(offered, "crew.ask"),
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

  defp crew(_ctx, _roster, _offered, false = _soul?), do: []

  # The room's requests still waiting on a reply, which the prompt lists
  # with their age: a daily or a workspace thread's; a child thread holds
  # none.
  defp requests(ctx, %{kind: kind, id: thread_id}) when kind in @rooms do
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
  # A crew member's bytes resolve under the soul's tools as they stand, so
  # a soul whose tools moved since the turn started moves the digest and
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
      "mode" => parsed.mode,
      "tools" => parsed.tools,
      "catalyst_ref" => parsed.catalyst_ref,
      "program" => Map.get(parsed, :program),
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
    case Map.get(turn, :program) || agent["program"] do
      row_id when is_binary(row_id) ->
        with {:ok, program} <- program(ctx, row_id),
             :ok <- holds(turn, agent, {:driver, program.driver}, program.name),
             do: {:ok, {nil, Map.delete(program, :driver)}, turn.model || agent["model"]}

      nil ->
        catalyst_model(ctx, turn, agent)
    end
  end

  defp catalyst_model(ctx, turn, agent) do
    listing =
      case Aqua.AgentConfig.catalyst_listing(ctx) do
        {:ok, listing} -> listing
        {:error, _} -> []
      end

    with {:ok, catalyst, model} <- catalyst(listing, turn, agent),
         :ok <- speaks_chat(listing, catalyst),
         :ok <- holds(turn, agent, {:needs, needs(listing, catalyst)}, brain_name(catalyst)) do
      if is_binary(model), do: {:ok, {catalyst, nil}, model}, else: {:error, :no_model}
    end
  end

  # A read-only member's brain must be one CYFR keeps read-only
  # (`Aqua.Models.holds_read_only?/1`): this is the first point the turn
  # reads its catalyst's manifest or its program row, after the root's
  # claim and before anything runs, and a turn refused here ends unrun
  # with the sentence as a line in its thread (`Aqua.Loop`).
  defp holds(%{mode: "read-only"}, agent, brain, name) do
    if Aqua.Models.holds_read_only?(brain),
      do: :ok,
      else: {:error, {:read_only_unheld, agent["title"] || agent["name"], name}}
  end

  defp holds(_auto, _agent, _brain, _name), do: :ok

  defp needs(listing, catalyst) do
    row = Enum.find(listing, &(&1["component_ref"] == catalyst)) || %{}
    Prima.Manifest.Needs.from_manifest(row["manifest"])
  end

  defp brain_name(catalyst) do
    case Prima.ComponentRef.parse(catalyst) do
      {:ok, %{name: name}} when is_binary(name) -> name
      _unread -> catalyst
    end
  end

  # The program row a program brain runs on, as it stands now
  # (`Aqua.Models.program/2`): its epoch is the one the turn's
  # `program.start` names, which `Opus.Brain` holds every write to. A
  # program brain names its harness's model, if any, as the agent's
  # `model`; the harness's default stands for none.
  defp program(ctx, row_id) do
    case Aqua.Models.program(ctx, row_id) do
      {:ok, program} -> {:ok, program}
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, {state, _name}} -> {:error, state}
      {:error, state} -> {:error, state}
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
  # a cap of nil is a check that never fires. A program brain has no
  # catalyst, and so neither cap nor timeout.
  defp request_cap(_authority, nil), do: nil

  defp request_cap(authority, catalyst) do
    with {:ok, name_ref} <- Prima.ComponentRef.to_name_ref(catalyst),
         {:ok, %Prima.Limits{max_request_size: cap}} <-
           Prima.Authority.node_limits(authority, name_ref) do
      cap
    else
      _ -> nil
    end
  end

  # How long the brain is consented to take over one answer, in
  # milliseconds: the `limits.timeout` of its catalyst's node in the turn's
  # authority, read by name as `request_cap/2` is. It is the deadline
  # admission gives each model call and the worker service enforces
  # (`Opus.Admission`), so the turn's own deadline is never under it. Nil
  # when the graph holds no such node or its timeout does not parse:
  # admission refuses such a call before anything runs.
  defp brain_timeout_ms(_authority, nil), do: nil

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

  defp asked(false, _ctx, _authority, _catalyst, _model, _turn), do: {:ok, Aqua.Models.none()}

  defp asked(true, ctx, authority, catalyst, model, turn),
    do: capabilities(ctx, authority, catalyst, model, turn)

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
  # all. A crew member is offered the soul's tools, so it may as the soul may.
  defp launch_accounts(ctx, offered) do
    if Aqua.Offered.offered?(offered, "execution.run"),
      do: Aqua.Hands.launch_accounts(ctx),
      else: nil
  end

  # An outside server's tools the member is offered (`server:tool`), as
  # the catalog knows them.
  defp external_tools(offered) do
    for {key, "offered"} <- offered,
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
  The member's offered set as the person's browser setting stands now.

  `build/3`'s set is a snapshot. A person turning the browser setting off
  mid-turn writes the store; nothing rebuilds the snapshot a running loop
  decides from, so a call that has not dispatched yet is decided again
  here. The authored half is the pinned agent definition and is never
  re-read here; a mode switched mid-turn reaches the member's next turn.
  """
  @spec current_offered(t()) :: Aqua.Offered.t()
  def current_offered(%__MODULE__{ctx: ctx, agent: agent, options: options}) do
    agent["tools"]
    |> Aqua.Offered.resolve(Aqua.BrowserSetting.allowed?(ctx))
    |> narrowed((options || %{})["tools"])
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

  # The initiating message's attachments as blocks the brain takes, each
  # stored under that message's own row: a delivered request's were copied
  # there from the request (`Aqua.Crew`).
  defp attachments(ctx, %{message_id: message_id}, media_types) when is_binary(message_id) do
    case Tape.message(ctx, message_id) do
      {:ok, row} -> file_blocks(ctx, row, media_types)
      _ -> []
    end
  end

  defp attachments(_ctx, _turn, _media_types), do: []

  @doc """
  A post's files as blocks a brain declaring `media_types` takes, read
  from the post's own row: the turn's initiating post's, and each later
  post written into the turn (`Aqua.Loop`). A file whose bytes are gone
  is left out.
  """
  @spec file_blocks(Context.t(), Tape.row(), [String.t()]) :: [map()]
  def file_blocks(%Context{} = ctx, row, media_types) do
    ctx
    |> Aqua.Attachments.load(row.thread_id, Aqua.Attachments.attachments_of([row]))
    |> Enum.map(&attachment_block(&1, media_types))
  end

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
end
