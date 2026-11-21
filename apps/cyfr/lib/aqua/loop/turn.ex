# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Turn do
  @moduledoc """
  What a loop runs, rebuilt from rows: the turn and its thread, the
  agent as the turn pinned it — the revision bytes, resolved as the agent
  runs (a crew member offered the soul's tools, the soul seated on the
  crew member its bytes name, `Compendium.resolve_agent/3`), whose
  capability digest must equal the
  one the turn started under — the roster, the member's mode and the set
  it is offered (`Aqua.Offered`), the same on every job, the resolved
  model catalyst with its capabilities
  and the request size its consent caps it at (`request_cap`), the brain
  options — the agent file's own, over which a crew request's
  (`options["brain_options"]`) set theirs — the system prompt (the
  soul's prompt or a crew member's opening, then CYFR's part for its
  kind of brain, `Aqua.Prompt.briefing/2`; the soul's brain is its
  member's), the tool
  surface (with the accounts its launches may name,
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
  # A catalyst's refusal that its key is not there to use.
  @key_refusals ~w(secret_denied)

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
    # The grant a catalyst brain's model calls run under: the brain's own,
    # never Aqua's (`brain_grant/3`). Nil for a program brain.
    :brain_authority,
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
    :excerpt,
    :attachments,
    soul?: true
  ]

  @doc """
  Build the spec for `turn` as `ctx` (the actor's external-plane context).
  `opts`: `:authority` (the turn's pinned authority, required) and
  `:excerpt?` (read the room excerpt the turn's options name).

  A catalyst brain's own grant is the one the turn's row pinned with its
  start (`brain_pin/5`), and nothing else: a turn whose row pins none
  asks no model (a page's call, a server's line that no longer stands),
  so no brain grant is loaded or checked, its brain is not described and
  its capabilities are none (`Aqua.Models.none/0`). A program brain's row
  is pinned here (`Tape.pin_program/3`), before anything runs on it, and
  the spec carries the turn's row as pinned.

  Refuses Aqua whose crew member does not stand (`{:aqua_runs_on,
  state, member}`, `Compendium.AquaAgent.seated/2`), a program brain
  whose row does not (`{:crew_unready, title, state}`), an agent that
  names no model (`:no_model`), a catalyst the
  athanor does not hold or that does not speak `model/chat@1`, and a
  model its catalyst cannot describe (`Aqua.Models.capabilities/5`; a
  typed refusal is `{:model_refused, catalyst, error}`, and a catalyst
  whose consent lacks its key `{:setup_required, catalyst}`), a catalyst
  whose own grant is missing, revoked or stale (`{:setup_required,
  catalyst}`), a catalyst whose own grant is damaged or cannot be read
  (`{:crew_unready, title, state}`), and a pinned brain grant whose head
  moved (`:consent_moved`).
  """
  @spec build(Context.t(), Tape.turn(), keyword()) :: {:ok, t()} | {:error, term()}
  def build(%Context{} = ctx, turn, opts) do
    authority = Keyword.fetch!(opts, :authority)

    with {:ok, thread} <- Tape.thread(ctx, turn.thread_id),
         {:ok, roster} <- Aqua.AgentConfig.roster(ctx),
         {:ok, agent} <- agent(ctx, turn),
         :ok <- held(agent),
         soul? = Prima.AgentRef.soul?(agent["name"]),
         options = decode(turn.options),
         brain_options = Map.merge(agent["options"] || %{}, options["brain_options"] || %{}),
         offered = Aqua.Offered.resolve(agent["tools"], Aqua.BrowserSetting.allowed?(ctx)),
         {:ok, brain, model} <- model(ctx, turn, agent),
         {catalyst, program} = brain,
         {:ok, turn, brain_authority} <- brain(ctx, turn, agent, brain),
         asks? = brain_authority != nil,
         {:ok, capabilities} <-
           brain_said(
             ctx,
             agent,
             catalyst,
             asked(asks?, ctx, brain_authority, catalyst, model, turn)
           ),
         :ok <- if(asks?, do: brain_options(brain_options, capabilities), else: :ok) do
      prompt =
        Aqua.Prompt.compose(ctx,
          agent: agent,
          program?: program != nil,
          search?: Request.offers_search?(offered, authority, capabilities),
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
        brain_authority: brain_authority,
        catalyst: catalyst,
        program: program,
        model: model,
        capabilities: capabilities,
        request_cap: request_cap(brain_authority, catalyst),
        system: prompt.text,
        tools:
          Request.tool_definitions(offered,
            external: external_tools(offered),
            accounts: launch_accounts(ctx, offered)
          ),
        deadline_ms: deadline_ms(authority, brain_timeout_ms(brain_authority, catalyst)),
        options: options,
        brain_options: brain_options,
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

  # Aqua runs on the crew member its pinned bytes name, which must supply
  # its brain; a crew member holds no one.
  defp held(%{"holder" => %{state: :held}}), do: :ok

  defp held(%{"holder" => %{state: state, name: member}}),
    do: {:error, {:aqua_runs_on, state, member}}

  defp held(_crew), do: :ok

  defp agent_map(%{name: name} = parsed) do
    %{
      "name" => name,
      "holder" => parsed.holder,
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

  # The brain a turn runs on. A program brain: once the turn's row pins a
  # program row, exactly that row, read by its id, in recovery too; before,
  # the row of the name the agent names, resolved once here and pinned
  # after (`Aqua.Loop`), so a row replaced under that name is the next
  # turn's and never a pinned one's. A catalyst brain: once its row pins
  # one, exactly that release; before, the agent's catalyst resolved
  # against the working athanor's listing. It must be installed and speak
  # `model/chat@1`. A switch of the agent's brain reaches the next turn;
  # what a turn already sent to its provider stays that provider's.
  defp model(ctx, %{program: row_id} = turn, agent) when is_binary(row_id),
    do: program_model(turn, agent, Aqua.Models.pinned_program(ctx, row_id))

  defp model(ctx, turn, %{"program" => name} = agent) when is_binary(name),
    do: program_model(turn, agent, Aqua.Models.program(ctx, name))

  defp model(ctx, turn, agent), do: catalyst_model(ctx, turn, agent)

  # The program row a program brain runs on, as it stands now: its epoch
  # is the one the turn's `program.start` names, which `Opus.Brain` holds
  # every write to. A program brain names its harness's model, if any, as
  # the agent's `model`; the harness's default stands for none.
  defp program_model(turn, agent, {:ok, program}) do
    with :ok <- holds(turn, agent, {:driver, program.driver}, program.name),
         do: {:ok, {nil, Map.delete(program, :driver)}, turn.model || agent["model"]}
  end

  # A program row that does not stand is said as the member's card says
  # it, naming whose brain it is: Aqua's is its member's, whose card
  # installs or opens it.
  defp program_model(_turn, agent, {:error, {state, _name}}),
    do: {:error, {:crew_unready, brain_title(agent), state}}

  defp program_model(_turn, _agent, {:error, :unavailable}), do: {:error, :unavailable}

  defp program_model(_turn, agent, {:error, state}),
    do: {:error, {:crew_unready, brain_title(agent), state}}

  defp catalyst_model(ctx, turn, agent) do
    listing =
      case Aqua.AgentConfig.catalyst_listing(ctx) do
        {:ok, listing} -> listing
        {:error, _} -> []
      end

    with {:ok, catalyst, model} <- catalyst(listing, turn, agent),
         :ok <- speaks_chat(listing, catalyst) do
      if is_binary(model), do: {:ok, {catalyst, nil}, model}, else: {:error, :no_model}
    end
  end

  # A read-only member's program brain, Aqua's member's included, must be
  # one CYFR keeps read-only (`Aqua.Models.holds_read_only?/1`): this is
  # the first point the turn reads its program row, after the root's
  # claim and before anything runs, and a turn refused here ends unrun
  # with the sentence as a line in its thread (`Aqua.Loop`). The mode is
  # the one the turn's row stored at its start (`turns.agent_mode`).
  # Aqua's mode is its member's, so the sentence names the member whose
  # mode the person switches.
  defp holds(%{agent_mode: "read-only"}, agent, brain, name) do
    if Aqua.Models.holds_read_only?(brain),
      do: :ok,
      else: {:error, {:read_only_unheld, brain_title(agent), name}}
  end

  defp holds(_auto, _agent, _brain, _name), do: :ok

  @doc "A catalyst's refusal types that say its key is not there to use."
  @spec key_refusals() :: [String.t()]
  def key_refusals, do: @key_refusals

  @doc """
  Whose brain and mode the agent's are, as a person reads them: Aqua's are
  its member's.
  """
  @spec brain_title(map()) :: String.t()
  def brain_title(%{"holder" => %{title: title}}) when is_binary(title), do: title
  def brain_title(agent), do: title(agent)

  defp title(agent), do: agent["title"] || agent["name"]

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

  # The grant a catalyst brain's model calls run under: the brain's own,
  # its key, network and limits, never Aqua's, which names no brain. The
  # host loads it from the brain the agent names in the authenticated
  # athanor, never from anything a caller sends; each call is the brain's
  # own node invoking itself under it (`Prima.Authority.Transition`'s
  # self-invocation), as the brain runs when a person runs it. It is the
  # brain's profile labelled "default", the one its setup's key entry
  # writes, however many other profiles the person keeps on it
  # (`brain_pin/5`). Once the turn has started, its row is the only source
  # of it: a turn loads exactly the grant it pinned, by its profile, in
  # recovery too, and refuses one whose head moved since (`:consent_moved`,
  # as Aqua's pin is refused). It is loaded with the turn's reservation,
  # so every call is charged to the turn's root budget. A program brain has
  # none: its turn starts its program by the program's own row.
  @brain_label "default"

  @doc """
  The brain `turn`, about to start, pins with its start
  (`Tape.start_turn/3`, in the write that holds Aqua's pin): for a turn
  that asks its model (`asks?`) on a catalyst brain, the release the
  agent's catalyst (`parsed`, the agent as its snapshot resolved it)
  resolves to and the brain's own grant, loaded with the
  turn's reservation `budget_id`, as `%{catalyst_ref, brain_profile_id,
  brain_consent_id}`; nothing (`%{}`) for a turn that asks no model, a
  program brain, or an agent whose brain does not resolve, which
  `build/3` refuses as it does. A brain that cannot be used is refused as
  the brain (`{:crew_unready, title, state}`).
  """
  @spec brain_pin(
          Context.t(),
          Tape.turn(),
          map(),
          String.t() | nil,
          boolean()
        ) :: {:ok, map()} | {:error, term()}
  def brain_pin(ctx, turn, parsed, budget_id, asks?)

  # A turn whose row already pins a program row runs on that row, as
  # `build/3` reads it.
  def brain_pin(%Context{}, %{program: row}, _parsed, _budget_id, _asks?) when is_binary(row),
    do: {:ok, %{}}

  def brain_pin(%Context{} = ctx, _turn, parsed, budget_id, true = _asks?) do
    agent = agent_map(parsed)

    with %{"program" => nil} <- agent,
         {:ok, {catalyst, nil}, _model} <-
           catalyst_model(ctx, %{catalyst_ref: nil, model: nil}, agent),
         {:ok, authority} <-
           brain_said(ctx, agent, catalyst, default_brain(ctx, catalyst, budget_id)) do
      {:ok,
       %{
         catalyst_ref: catalyst,
         brain_profile_id: authority.profile_id,
         brain_consent_id: authority.consent_id
       }}
    else
      {:error, {:crew_unready, _title, _state}} = unready -> unready
      {:error, :consent_moved} = moved -> moved
      _program_or_unresolved -> {:ok, %{}}
    end
  end

  def brain_pin(%Context{}, _turn, _parsed, _budget_id, false = _asks?), do: {:ok, %{}}

  # The brain the turn runs on, from its row: a program brain's row,
  # pinned once; a catalyst brain's own grant, exactly the one the row
  # pinned. A turn whose row pins no brain grant asks no model (a page's
  # call, a server's line that no longer stands): it loads and checks none,
  # recovered or not.
  defp brain(_ctx, %{program: row} = turn, _agent, {nil, %{row: row}}), do: {:ok, turn, nil}

  defp brain(ctx, turn, _agent, {nil, %{row: row}}) do
    with {:ok, turn} <- Tape.pin_program(ctx, turn, row), do: {:ok, turn, nil}
  end

  defp brain(ctx, %{brain_profile_id: profile_id} = turn, agent, {catalyst, nil})
       when is_binary(profile_id) do
    with {:ok, authority} <- brain_said(ctx, agent, catalyst, pinned_brain(ctx, turn, catalyst)),
         do: {:ok, turn, authority}
  end

  defp brain(_ctx, turn, _agent, _unpinned), do: {:ok, turn, nil}

  @doc """
  The spec with its brain's own grant loaded and pinned on the turn's row
  (`turn`, as the loop holds it now), for a turn whose row pins none
  because it asked no model when it started (a page's call) and that a
  steer now asks one: nothing ran under any brain grant before, so its
  first is the brain's grant as it stands, pinned before the model is
  asked, and refused as `brain_pin/5` refuses it. A spec that holds its
  grant, or whose brain is a program, is answered as it is.
  """
  @spec with_brain(t()) :: {:ok, t()} | {:error, term()}
  def with_brain(%__MODULE__{catalyst: catalyst, brain_authority: nil} = spec)
      when is_binary(catalyst) do
    with {:ok, authority} <-
           brain_said(
             spec.ctx,
             spec.agent,
             catalyst,
             default_brain(spec.ctx, catalyst, spec.turn.budget_id)
           ),
         {:ok, turn} <- Tape.pin_catalyst(spec.ctx, spec.turn, catalyst, authority) do
      {:ok,
       %{
         spec
         | turn: turn,
           brain_authority: authority,
           request_cap: request_cap(authority, catalyst),
           deadline_ms: deadline_ms(spec.authority, brain_timeout_ms(authority, catalyst))
       }}
    end
  end

  def with_brain(%__MODULE__{} = spec), do: {:ok, spec}

  defp default_brain(ctx, catalyst, budget_id) do
    with {:ok, name_ref} <- Prima.ComponentRef.to_name_ref(catalyst) do
      ctx
      |> Opus.authority_for({:label, @brain_label}, name_ref, budget_id: budget_id)
      |> classified(catalyst)
    end
  end

  defp pinned_brain(ctx, turn, catalyst) do
    with {:ok, name_ref} <- Prima.ComponentRef.to_name_ref(catalyst) do
      case Opus.authority_for(ctx, {:id, turn.brain_profile_id}, name_ref,
             budget_id: turn.budget_id
           ) do
        {:ok, %{consent_id: consent_id} = authority} when consent_id == turn.brain_consent_id ->
          {:ok, authority}

        {:ok, _moved} ->
          {:error, :consent_moved}

        error ->
          classified(error, catalyst)
      end
    end
  end

  # A brain whose own grant is missing, revoked or stale is the brain's to
  # set up (`{:setup_required, catalyst}`); one whose grant is damaged or
  # cannot be read is the brain's state too (`{:brain_unready, state}`):
  # both said as the brain (`brain_said/4`).
  defp classified({:ok, _authority} = loaded, _catalyst), do: loaded

  defp classified({:error, reason}, catalyst) do
    case Aqua.ConsentStatus.classify_refusal(reason) do
      {:ok, _absent_or_stale} -> {:error, {:setup_required, catalyst}}
      {:error, :corrupt} -> {:error, {:brain_unready, :consent_damaged}}
      {:error, _unread} -> {:error, {:brain_unready, :unavailable}}
    end
  end

  # A brain not set up, its grant never given or taken away or its key
  # not entered, is the brain's own state, said as its card and its row in
  # Aqua's setup say it (`Aqua.Crew.unready/1` over
  # `Aqua.Models.model_status/2`) and named by whose brain it is: the
  # refusal the turn's line says, pointing at the Aqua page. A grant that
  # stands but holds no key is read against the brain's own setup before
  # anything runs, since a run with no key would only meet its provider's
  # refusal; a catalyst that says its key is not there is a key to enter.
  defp brain_said(ctx, agent, catalyst, {:ok, %Authority{resources: %{vault: nil}}} = loaded) do
    case brain_state(ctx, catalyst) do
      :ready -> loaded
      state -> {:error, {:crew_unready, brain_title(agent), state}}
    end
  end

  defp brain_said(ctx, agent, catalyst, {:error, {:setup_required, catalyst}}) do
    state =
      case brain_state(ctx, catalyst) do
        # Read ready, yet its grant did not stand a moment ago: one that
        # cannot be read now, to retry.
        :ready -> :unavailable
        state -> state
      end

    {:error, {:crew_unready, brain_title(agent), state}}
  end

  # A brain's own grant that is damaged or cannot be read is the brain's
  # state too, said as its card says it.
  defp brain_said(_ctx, agent, _catalyst, {:error, {:brain_unready, state}}),
    do: {:error, {:crew_unready, brain_title(agent), state}}

  defp brain_said(_ctx, agent, catalyst, {:error, {:model_refused, catalyst, %{"type" => type}}})
       when type in @key_refusals,
       do: {:error, {:crew_unready, brain_title(agent), :no_key}}

  defp brain_said(_ctx, _agent, _catalyst, answered), do: answered

  defp brain_state(ctx, catalyst) do
    {:ok, name_ref} = Prima.ComponentRef.to_name_ref(catalyst)
    brain = [%{"name" => "brain", "catalyst_ref" => name_ref}]
    Aqua.Crew.unready(Aqua.Models.model_status(ctx, brain)["brain"])
  end

  # The request size the consent graph caps the catalyst at, or nil. Read
  # by name, without the version: the spec carries a versioned ref because
  # that is what resolved, but the graph keys every node by name
  # (`Opus.Admission` steps by name), so a versioned key finds nothing and
  # a cap of nil is a check that never fires. A program brain has no
  # catalyst, and so neither cap nor timeout.
  defp request_cap(nil, _catalyst), do: nil
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
  # milliseconds: the `limits.timeout` of its catalyst's node in the
  # brain's own grant, read by name as `request_cap/2` is. It is the deadline
  # admission gives each model call and the worker service enforces
  # (`Opus.Admission`), so the turn's own deadline is never under it. Nil
  # when the graph holds no such node or its timeout does not parse:
  # admission refuses such a call before anything runs.
  defp brain_timeout_ms(nil, _catalyst), do: nil
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
  def current_offered(%__MODULE__{ctx: ctx, agent: agent}),
    do: Aqua.Offered.resolve(agent["tools"], Aqua.BrowserSetting.allowed?(ctx))

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
    |> Enum.map(&file_block(&1, media_types))
  end

  @doc """
  One loaded file (`Aqua.Attachments.load/3`) as the block a brain
  declaring `media_types` takes. It goes inline, as the image or document
  block its media type makes, only when the brain declares that type (its
  capabilities' `media_types`, or the media types a program's wire
  carries); a text file it does not take goes as a text block under its
  name; any other file is named as attached and not readable by this
  brain. No request carries a block the brain refuses.
  """
  @spec file_block(map(), [String.t()]) :: map()
  def file_block(%{"media_type" => media, "data" => data, "filename" => name}, types) do
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
