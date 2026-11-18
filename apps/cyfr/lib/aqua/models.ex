# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Models do
  @moduledoc """
  The assistant's model work over `model/chat@1` (`Prima.Model`, which
  names the contract and reads its envelope):

    * `capabilities/5` — what one model can do and the options it lets a
      caller set, read from its catalyst's `describe` and cached under the
      key the reading ran with; `brain_options/2` is the options of an
      agent's brain, read as a person on the Aqua page;
    * `catalogue/1` — the listing the console's pickers show, every
      installed catalyst that speaks the contract and has what it needs
      connected asked for its models;
    * `model_status/2` — whether each agent's brain is ready: installed,
      and bound to a key or a program the agent runs it with, or, for a
      brain that is a program, its program row standing (`t:status/0`);
    * `providers/1` — every brain the athanor can connect, with what it
      needs and how it stands, which Aqua's setup offers;
    * `models/2` — one brain asked for its models, the answer connecting
      shows.

  The component facts come from `Compendium.model_catalysts/1`; running a
  catalyst goes through the gate like any other call, under the caller's
  own plane.
  """

  alias Sanctum.Context

  @typedoc """
  An agent's brain as `model_status/2` reads it. The first five carry the
  release the agent's ref resolves to; `:missing` and `:model_unavailable`
  carry the ref the agent names, whether or not the listing resolved it:

    * `:ready` — the agent runs it with a bound key, or a bound program
      row for a brain that runs a program on its own sign-in, which is
      signed in when the program says so;
    * `:needs_key` — a key to connect;
    * `:needs_grant` — the person's grant is all it asks, as Aqua's
      setup reads it (`t:provider/0`): a brain that needs nothing else,
      or one whose every required need is a program's own sign-in (a login
      need) with each program's row set up here and none bound yet;
    * `:needs_program` — a brain whose every required need is a
      program's own sign-in, with a program it needs not set up here:
      its program to set up on the Programs page and its grant to give;
    * `:consent_stale` — the agent's own consent no longer covers its
      shape (its brain, model, options or capabilities changed since it
      was consented), so it runs again once the person consents again;
    * `:consent_damaged`, `:consent_unavailable` — a consent it runs
      under is damaged, or the store could not answer it;
    * `:missing` — the athanor's catalysts, read, hold no such model, or
      its setup plan answers that the registry holds no such component;
    * `:model_unavailable` — the athanor's catalysts could not be read,
      or its setup plan was refused for any other reason, so whether it is
      installed is not known.

  A brain that is a program (the agent's `"program"`, a program row's id)
  reads on its row alone, since each of its turns is admitted by that
  turn's own `program.start` step: `:ready` when the row stands as a
  brain's (the athanor's own, a driven program with a kept folder, not
  Aqua's browser, enabled), `:program_unfit` when it is not a program a
  brain runs in and `:program_disabled` when it is turned off, each
  carrying the row's name; `:program_missing` when the athanor holds no
  such row and `:model_unavailable` when the store could not answer, each
  carrying the id the agent names.
  """
  @type status ::
          {:ready
           | :needs_key
           | :needs_grant
           | :needs_program
           | :consent_stale
           | :consent_damaged
           | :consent_unavailable
           | :missing
           | :model_unavailable
           | :program_missing
           | :program_disabled
           | :program_unfit, String.t()}

  # A listing runs every contract catalyst the athanor holds; each is one
  # root execution and one provider round trip.
  @listing_concurrency 5
  @listing_timeout_ms 30_000
  @capabilities_ttl_ms :timer.hours(24)

  @doc """
  The capabilities of `model` on `resolved_ref`: the catalyst's
  `describe` of that model, run through `run` — a function the caller
  supplies that runs one contract operation on the catalyst under the
  caller's own authority (`%{"operation" => op, "params" => params}` →
  `{:ok, result} | {:error, _}`), so a guest-planed loop reads through
  its pinned authority. Cached for a day under the resolved reference,
  the model and `binding_digest` (the key the reading ran with).

  Options: `:run` (required) and `:timeout`, the milliseconds the
  `describe` may take before it is stopped (unbounded when absent).

  Errors: `{:unknown_model, model}` when the catalyst does not know the
  model; `{:model_refused, error}` for any other typed refusal (the
  error map, e.g. `secret_denied` when describing the model takes a key
  that is not bound); `{:no_context_window, model}` when the answer
  names no window; `{:invalid_options, model, member}` when the options
  it declares break the contract (`Prima.Model.options/1`; an answer
  without options declares none); `{:describe_failed, reason}` when the
  run failed, `reason` `:timeout` when it outran `:timeout`. No error is
  cached.
  """
  @spec capabilities(Context.t(), String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, Prima.Model.capabilities()} | {:error, term()}
  def capabilities(%Context{} = ctx, resolved_ref, model, binding_digest, opts)
      when is_binary(model) do
    run = opts |> Keyword.fetch!(:run) |> bounded(Keyword.get(opts, :timeout))
    key = {:model_caps, Context.athanor!(ctx), resolved_ref, model, binding_digest}

    case Arca.Cache.get(key) do
      {:ok, caps} ->
        {:ok, caps}

      :miss ->
        with {:ok, caps} <- describe_model(model, run) do
          Arca.Cache.put(key, caps, @capabilities_ttl_ms)
          {:ok, caps}
        end
    end
  end

  # With a deadline the run happens in a supervised task that is killed
  # when the deadline passes, so a catalyst that never answers stops, and
  # whatever the run started stops with the task that owned it.
  defp bounded(run, timeout) when timeout in [nil, :infinity], do: run

  defp bounded(run, timeout) when is_integer(timeout) and timeout > 0 do
    fn input ->
      task = Task.Supervisor.async_nolink(Aqua.TaskSupervisor, fn -> run.(input) end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, answer} -> answer
        {:exit, reason} -> {:error, {:exit, reason}}
        nil -> {:error, :timeout}
      end
    end
  end

  @doc """
  The capabilities of a turn that asks no model (`Aqua.Loop.Turn.build/3`
  for a turn a page's call opened): none, and no description asked for.
  """
  @spec none() :: map()
  def none do
    %{
      context_window: nil,
      max_output_tokens: nil,
      max_input_tokens: nil,
      provider_tools: [],
      media_types: [],
      streaming: false,
      default_max_tokens: nil,
      options: []
    }
  end

  defp describe_model(model, run) do
    with {:ok, result} <- ran(run.(%{"operation" => "describe", "params" => %{"model" => model}})),
         {:ok, described} <- described(Prima.Model.decode_envelope(result), model),
         {:ok, window} <- window(described, model),
         {:ok, options} <- options(described, model) do
      {:ok,
       %{
         context_window: window,
         max_output_tokens: positive(described["max_output_tokens"]),
         max_input_tokens: positive(described["max_input_tokens"]),
         provider_tools: list_of_strings(described["provider_tools"]),
         media_types: list_of_strings(described["media_types"]),
         streaming: described["streaming"] == true,
         default_max_tokens: positive(get_in(described, ["defaults", "max_tokens"])),
         options: options
       }}
    end
  end

  defp options(described, model) do
    case Prima.Model.options(described) do
      {:ok, options} -> {:ok, options}
      {:error, {:invalid, member}} -> {:error, {:invalid_options, model, member}}
    end
  end

  defp ran({:ok, result}), do: {:ok, result}
  defp ran({:error, reason}), do: {:error, {:describe_failed, reason}}

  defp described({:ok, data}, _model), do: {:ok, data}

  defp described({:error, %{"type" => "unknown_model"}}, model),
    do: {:error, {:unknown_model, model}}

  defp described({:error, error}, _model), do: {:error, {:model_refused, error}}

  # The window is the one limit a planner cannot do without: an answer
  # that bounds the input but names no window is refused, not sized from
  # the ceiling, because the ceiling says nothing about the output's share.
  defp window(described, model) do
    case positive(described["context_window"]) do
      nil -> {:error, {:no_context_window, model}}
      window -> {:ok, window}
    end
  end

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: nil

  defp list_of_strings(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp list_of_strings(_), do: []

  @doc """
  The options `agent`'s brain lets a caller set — the roster's
  string-keyed projection, its `"catalyst_ref"` and `"model"` — as the
  brain's `describe` of that model declares them (`capabilities/5`), read
  as the caller through the catalog like `catalogue/1`'s listing, within
  30 seconds. An agent that names no catalyst, a program brain's
  included, declares none; a catalyst the athanor does not hold is
  `{:error, :catalyst_not_found}`, and a `describe` that fails is
  `capabilities/5`'s refusal.
  """
  @spec brain_options(Context.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def brain_options(%Context{} = ctx, %{"catalyst_ref" => ref, "model" => model})
      when is_binary(ref) and ref != "" and is_binary(model) and model != "" do
    with {:ok, listing} <- Aqua.AgentConfig.catalyst_listing(ctx),
         {:ok, resolved} <- Aqua.AgentConfig.resolve_catalyst(listing, ref),
         {:ok, caps} <-
           capabilities(ctx, resolved, model, nil,
             run: &run_as_caller(ctx, resolved, &1),
             timeout: @listing_timeout_ms
           ) do
      {:ok, caps.options}
    end
  end

  def brain_options(%Context{}, _agent), do: {:ok, []}

  defp run_as_caller(ctx, resolved, input) do
    Aqua.Ops.call_tool("execution", ctx, %{
      "action" => "run",
      "reference" => resolved,
      "type" => "catalyst",
      "input" => input
    })
  end

  @doc """
  The model listing the console shows: every installed catalyst that
  declares the contract, at its newest version, asked for `models`
  through the catalog, so consent applies to what runs. A catalyst whose
  setup plan (`component.setup_plan`, as `model_status/2` reads it)
  leaves a key, a program or its grant to connect is not run, and no run,
  failed or otherwise, is recorded for it. It is listed under `errors` with
  `:connection_not_granted`'s sentence, the one its run is refused with.
  Any other plan, or a plan that cannot be read, runs the listing, whose
  own refusal is the catalyst's row: a program not signed in is the
  catalyst's to say.

  Returns `{:ok, %{"models" => %{provider => [id]}, "refs" => %{provider
  => versionless ref}, "errors" => %{provider => message}}}`. A provider
  is the catalyst's name, prefixed by its namespace when that is not the
  local one, so two catalysts never share a row. A caller that may not
  read the athanor's components is `{:error, :forbidden}`; a component
  store that cannot answer is `{:error, :unavailable}`.
  """
  @spec catalogue(Context.t()) :: {:ok, map()} | {:error, :forbidden | :unavailable}
  def catalogue(%Context{} = ctx) do
    with {:ok, rows} <- Compendium.model_catalysts(ctx) do
      catalysts = newest_speaking(rows)

      results =
        Aqua.TaskSupervisor
        |> Task.Supervisor.async_stream_nolink(
          catalysts,
          fn {provider, ref} -> {provider, ref, list_models(ctx, ref)} end,
          max_concurrency: @listing_concurrency,
          timeout: @listing_timeout_ms,
          on_timeout: :kill_task
        )
        |> Enum.zip(catalysts)
        |> Enum.map(fn
          {{:ok, answered}, _} -> answered
          {{:exit, _}, {provider, ref}} -> {provider, ref, {:error, "the listing did not answer"}}
        end)

      {:ok,
       Enum.reduce(results, %{"models" => %{}, "refs" => %{}, "errors" => %{}}, fn
         {provider, ref, {:ok, ids}}, acc ->
           acc
           |> put_in(["models", provider], ids)
           |> put_in(["refs", provider], ref)

         {provider, ref, {:error, message}}, acc ->
           acc
           |> put_in(["refs", provider], ref)
           |> put_in(["errors", provider], message)
       end)}
    end
  end

  # The newest installed version of every catalyst declaring the contract,
  # as `{provider, versionless_ref}`.
  defp newest_speaking(rows) do
    chat = Prima.Model.chat_contract()

    rows
    |> Enum.filter(&(chat in &1.contracts))
    |> Enum.group_by(&{&1.publisher, &1.name})
    |> Enum.map(fn {{publisher, name}, versions} ->
      newest = versions |> Prima.Semver.sort_desc_by(&(&1.version || "0")) |> hd()
      {provider_key(publisher, name), newest.node_key}
    end)
    |> Enum.sort()
  end

  defp provider_key(publisher, name) do
    case Prima.ComponentPath.normalize_publisher(publisher) do
      "local" -> name
      namespace -> "#{namespace}.#{name}"
    end
  end

  # A listing opened on every pane mount runs nothing for a catalyst
  # still waiting on its key, program or grant: such a run could only
  # fail, and a failed run stands as something waiting on the person
  # (`Cyfr.Providers.Attention`).
  defp list_models(ctx, ref) do
    case to_connect(ctx, ref) do
      nil -> ask_models(ctx, ref)
      sentence -> {:error, sentence}
    end
  end

  # What the catalyst's own consent leaves the person to connect, as the
  # sentence its row shows, or nil to run it: a damaged consent, one the
  # store could not answer, or a plan that could not be read is no setup
  # the person can make, and runs as it always has.
  defp to_connect(ctx, ref) do
    case Aqua.Ops.call_tool("component", ctx, %{"action" => "setup_plan", "reference" => ref}) do
      {:ok, %{ready: false} = plan} ->
        case unready(plan, ref) do
          {:connect, _} -> refusal_text(:connection_not_granted)
          _no_setup -> nil
        end

      _ready_or_unread ->
        nil
    end
  end

  defp ask_models(ctx, ref) do
    run = run_as_caller(ctx, ref, %{"operation" => "models", "params" => %{}})

    with {:ok, result} <- run,
         {:ok, %{"models" => models}} when is_list(models) <- Prima.Model.decode_envelope(result) do
      {:ok,
       models
       |> Enum.map(&(is_map(&1) && &1["id"]))
       |> Enum.filter(&(is_binary(&1) and &1 != ""))}
    else
      {:ok, _other} -> {:error, "the catalyst answered no model list"}
      {:error, %{"message" => message}} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, refusal_text(reason)}
    end
  end

  defp refusal_text(reason), do: Sanctum.Refusals.render(reason)

  @doc """
  The brain `ref` (an installed catalyst release that speaks
  `model/chat@1`) asked for its models once, through the catalog as the
  caller, whatever its setup reads: `{:ok, ids}`, or `{:error, sentence}`
  with the provider's own words when it refused (a key it does not take
  reads as the provider says so). What connecting a brain shows.
  """
  @spec models(Context.t(), String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def models(%Context{} = ctx, ref) when is_binary(ref), do: ask_models(ctx, ref)

  @typedoc """
  A brain the athanor can connect (`providers/1`): its `provider` (as
  `catalogue/1` names it), its versionless `ref`, which the newest
  installed release answers, the `need`
  connecting it meets — the first required one, `%{name, kind, qualifier,
  reason, program}` with `kind` `"login"` for a program's own sign-in and
  the credential kind otherwise (`qualifier` the provider its key is
  for), or nil for a brain that needs nothing — its `state` as its own
  consent reads it (`:needs_grant` for a brain never granted, or whose
  grant was revoked, that needs nothing else of the person: no required
  need, or only its programs' own, each set up here as a kept driven
  program row the grant binds), and `shared`, `%{owner, person_daily}`
  when what binds it is a key someone shared with the person.
  """
  @type provider :: %{
          provider: String.t(),
          ref: String.t(),
          need: map() | nil,
          state:
            :ready
            | :needs_grant
            | :needs_key
            | :needs_program
            | :consent_damaged
            | :consent_unavailable
            | :model_unavailable,
          shared: %{owner: String.t(), person_daily: non_neg_integer() | nil} | nil
        }

  @doc """
  Every brain the athanor can connect: each installed catalyst that
  declares `model/chat@1`, at its newest version, read through its setup
  plan (`component.setup_plan`) as `t:provider/0`. A brain bound to a key
  shared with the person comes first, then the rest by provider. A brain
  installed later is listed on the next read; nothing here names one.
  A setup plan that cannot be read is that brain's `:model_unavailable`;
  the shares offered to the person that cannot be read leave `shared` nil.
  A caller that may not read the athanor's components is
  `{:error, :forbidden}`; a component store that cannot answer is
  `{:error, :unavailable}`.
  """
  @spec providers(Context.t()) :: {:ok, [provider()]} | {:error, :forbidden | :unavailable}
  def providers(%Context{} = ctx) do
    with {:ok, rows} <- Compendium.model_catalysts(ctx) do
      shares = offered_shares(ctx)
      programs = set_up_programs(ctx)

      {:ok,
       rows
       |> newest_speaking()
       |> Enum.map(fn {provider, ref} -> provider(ctx, provider, ref, shares, programs) end)
       |> Enum.sort_by(&{is_nil(&1.shared), &1.provider})}
    end
  end

  defp provider(ctx, provider, ref, shares, programs) do
    case Aqua.Ops.call_tool("component", ctx, %{"action" => "setup_plan", "reference" => ref}) do
      {:ok, plan} ->
        %{
          provider: provider,
          ref: ref,
          need: need_of(plan),
          state: plan_state(plan, ref, programs),
          shared: shared(plan, shares)
        }

      {:error, _unread} ->
        %{provider: provider, ref: ref, need: nil, state: :model_unavailable, shared: nil}
    end
  end

  defp need_of(plan) do
    case for(need <- plan[:needs] || [], need[:required] != false, do: need) do
      [need | _] -> Map.take(need, [:name, :kind, :qualifier, :reason, :program])
      [] -> nil
    end
  end

  defp plan_state(%{ready: true}, _ref, _programs), do: :ready

  defp plan_state(plan, ref, programs) do
    case unready(plan, ref) do
      {:connect, _} -> connect_state(plan, programs)
      {state, _} -> state
    end
  end

  # A brain with no grant to stand on, never made or revoked, and no
  # required need: the person's grant is all it asks, so no key is offered.
  # A required need already met before a revocation is not told apart
  # here, since an ungranted plan carries no binding to read it from. So
  # is a brain whose required needs are all its programs' own, each set
  # up here: the grant binds the program row its plan offers, granted
  # before or not. On a plan that reads ready, as an agent's status reads
  # it once the agent's edge binds nothing, the grant that waits is the
  # agent's own.
  defp grant_only?(plan, programs) do
    case head_state(plan) do
      state when state in ["damaged", "unavailable"] ->
        false

      state ->
        (state in ["missing", "revoked"] and is_nil(need_of(plan))) or
          (signs_in?(plan) and
             Enum.all?(required(plan), &MapSet.member?(programs, &1[:program])))
    end
  end

  # The programs set up here that a login need binds: the athanor's kept
  # driven program rows, by name (`Sanctum.Mount`). A list that cannot be
  # read sets none up.
  defp set_up_programs(ctx) do
    case Aqua.Ops.call_tool("mcp_servers", ctx, %{"action" => "list"}) do
      {:ok, %{servers: servers}} ->
        for %{transport: "program", mark: "driven", home: "kept", enabled: true, name: name} <-
              servers,
            into: MapSet.new(),
            do: name

      _unread ->
        MapSet.new()
    end
  end

  # A bound need whose binding is a share offered to the person: the share
  # the setup plan names is the one the person's consent holds.
  defp shared(plan, shares) do
    Enum.find_value(get_in(plan, [:consent, :needs]) || [], fn
      %{entry_id: id, satisfied: true} when is_map_key(shares, id) ->
        Map.take(shares[id], [:owner, :person_daily])

      _other ->
        nil
    end)
  end

  defp offered_shares(ctx) do
    case Aqua.Ops.call_tool("share", ctx, %{"action" => "offered"}) do
      {:ok, %{shares: shares}} -> Map.new(shares, &{&1.id, &1})
      _unread -> %{}
    end
  end

  @doc """
  For each agent given (the roster's string-keyed projection: `"name"`,
  `"catalyst_ref"` and `"program"`), its brain: the installed release its
  catalyst resolves to and whether the consent it runs under is complete —
  `%{name => t:status/0}`: `{:ready | :needs_key | :needs_grant |
  :needs_program | :consent_stale | :consent_damaged |
  :consent_unavailable, resolved_ref}`, or `{:missing | :model_unavailable,
  catalyst_ref}` — or, for a brain that is a program, how its row stands
  (`t:status/0`). An agent that names no brain has no entry. Each
  agent is read on its own consent, the soul's or the crew member's
  (`Compendium.AgentSource`), so a member whose brain is not installed
  or not bound reads so while the soul reads ready.

  A brain is ready on a bound need of either kind: a key the catalyst's
  requests carry, or a program row whose folder it runs its program in
  (`Sanctum.Mount`) — the setup plan and the edge read both the same
  way. A consent the brain runs under that is damaged, or that the
  store could not answer, is `:consent_damaged` or
  `:consent_unavailable`, never a key to connect over a consent that
  exists: the brain's own consent, as its setup plan reads it, and, once
  that reads ready, the agent's own load
  (`Aqua.ConsentStatus.classify_refusal/1`), whose stale consent is
  `:consent_stale`, a consent to give again. A catalyst listing that
  cannot be read is not an empty one, and a setup plan refused for any
  reason but the component's absence (`{:not_found, {:component, _}}`,
  `Compendium.Component.resolve_component/2`'s one absence) is not an
  absence: each is `:model_unavailable`, never a model to install.

  A soul with no key is the one thing that keeps a fresh athanor's Aqua
  silent, so both the Aqua page and the chat's own empty state ask here;
  the crew index (`Aqua.Crew.index/2`) names only the members that read
  ready.
  """
  @spec model_status(Context.t() | nil, [map()]) :: %{String.t() => status()}
  def model_status(nil, _agents), do: %{}

  def model_status(%Context{} = ctx, agents) when is_list(agents) do
    # The listing's refusal is kept: a listing that cannot be read never
    # resolves a model against no catalysts.
    listing = Aqua.AgentConfig.catalyst_listing(ctx)
    programs = set_up_programs(ctx)

    for %{"name" => name} = agent <- agents,
        is_binary(name),
        brain <- List.wrap(brain_of(agent)),
        into: %{} do
      case brain do
        {:program, id} -> {name, program_status(ctx, id)}
        {:catalyst, ref} -> {name, catalyst_status(ctx, listing, programs, name, ref)}
      end
    end
  end

  # The brain an agent names: its program row, or its catalyst. A file
  # names one at most (`Compendium.AquaAgent.check_brain/1`), and a map
  # that carries no program names its catalyst.
  defp brain_of(%{"program" => id}) when is_binary(id) and id != "", do: {:program, id}
  defp brain_of(%{"catalyst_ref" => ref}) when is_binary(ref) and ref != "", do: {:catalyst, ref}
  defp brain_of(_agent), do: nil

  defp program_status(ctx, id) do
    case program(ctx, id) do
      {:ok, %{name: name}} -> {:ready, name}
      {:error, {state, name}} when state in [:program_disabled, :program_unfit] -> {state, name}
      {:error, :program_missing} -> {:program_missing, id}
      {:error, :unavailable} -> {:model_unavailable, id}
    end
  end

  @doc """
  The program row a program brain names, as it stands now: `{:ok, %{row,
  epoch, name}}` for an enabled driven program with a kept folder, else
  `{:error, {:program_disabled | :program_unfit, name}}`,
  `{:error, :program_missing}` or `{:error, :unavailable}`. The holder
  checks the row again as it writes, and refuses Aqua's browser's rows
  there (`Opus.Brain`).
  """
  @spec program(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def program(%Context{} = ctx, id) when is_binary(id) do
    case Arca.McpServerStorage.get_by_id(Context.actor(ctx), id) do
      {:ok, %{transport: "program", mark: "driven", home: "kept", enabled: true} = row} ->
        {:ok, %{row: row.id, epoch: row.epoch, name: row.name}}

      {:ok, %{transport: "program", mark: "driven", home: "kept"} = row} ->
        {:error, {:program_disabled, row.name}}

      {:ok, row} ->
        {:error, {:program_unfit, row.name}}

      {:error, :not_found} ->
        {:error, :program_missing}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  # A brain is ready when its own profile binds what it needs AND the
  # agent's consent selects that profile on its edge to the catalyst —
  # what the agent actually runs it with, resolved as a turn would resolve
  # it. A bound key the agent's edge does not select is still one to
  # connect.
  defp catalyst_status(_ctx, {:error, _unread}, _programs, _name, ref),
    do: {:model_unavailable, ref}

  defp catalyst_status(ctx, {:ok, listing}, programs, name, ref) do
    case Aqua.AgentConfig.resolve_catalyst(listing, ref) do
      {:ok, resolved} -> planned_status(ctx, programs, name, ref, resolved)
      {:error, _no_such_catalyst} -> {:missing, ref}
    end
  end

  # The setup plan's refusal is classed on its typed reason: the
  # registry's answer that it holds no such component is an absence, and
  # every other refusal (a store that could not answer, which the
  # component domain answers as a sentence, a damaged row, a timeout, a
  # forbidden call, anything else) leaves whether it is installed unknown.
  defp planned_status(ctx, programs, name, ref, resolved) do
    case Aqua.Ops.call_tool("component", ctx, %{
           "action" => "setup_plan",
           "reference" => resolved
         }) do
      {:ok, plan} ->
        case plan_state(plan, resolved, programs) do
          :ready -> agent_status(ctx, name, ref, resolved, connect_state(plan, programs))
          state -> {state, resolved}
        end

      {:error, {:not_found, {:component, _reference}}} ->
        {:missing, ref}

      {:error, _refused} ->
        {:model_unavailable, ref}
    end
  end

  # The agent's own load, as a turn would make it, read through
  # `Aqua.ConsentStatus.classify_refusal/1`: a load that refuses for
  # damage (the agent's head, a lender, a stored grant that fails its
  # checks), because the store could not answer, or because the agent's
  # shape moved since its consent is said as such, never as a key to
  # connect; every other refusal, and an edge that binds nothing, is
  # `connect`, what connecting its brain asks (`connect_state/2`).
  defp agent_status(ctx, name, catalyst_ref, resolved, connect) do
    source = Prima.AgentRef.ref(name)

    case Opus.authority_for(ctx, :default, source) do
      {:ok, authority} ->
        if lent?(authority, source, catalyst_ref),
          do: {:ready, resolved},
          else: {connect, resolved}

      {:error, reason} ->
        case Aqua.ConsentStatus.classify_refusal(reason) do
          {:ok, :stale} -> {:consent_stale, resolved}
          {:error, :corrupt} -> {:consent_damaged, resolved}
          {:error, :unavailable} -> {:consent_unavailable, resolved}
          _absent_or_forbidden -> {connect, resolved}
        end
    end
  end

  # A bound vault is an entry, a key or a program row alike
  # (`Prima.Authority.Blob.bound_vault?/1`).
  defp lent?(authority, source, catalyst_ref) do
    case Prima.Authority.Blob.lookup_edge(authority.policy, source, catalyst_ref, "") do
      {:ok, edge} -> Prima.Authority.Blob.bound_vault?(edge.vault)
      _no_edge -> false
    end
  end

  # A plan that is not ready because the model's own consent is damaged,
  # or the store could not answer it, is nothing to connect: connecting
  # cannot repair a consent that exists. A head never granted, or no
  # profile, is `:connect`, which `connect_state/2` names.
  defp unready(plan, resolved) do
    case head_state(plan) do
      "damaged" -> {:consent_damaged, resolved}
      "unavailable" -> {:consent_unavailable, resolved}
      _missing_or_ungranted -> {:connect, resolved}
    end
  end

  # What connecting a brain asks of the person, the one rule Aqua's setup
  # and every agent's status read: its grant alone (`grant_only?/2`), else
  # a program to set up for a brain whose every required need is a
  # program's own sign-in, else a key.
  defp connect_state(plan, programs) do
    cond do
      grant_only?(plan, programs) -> :needs_grant
      signs_in?(plan) -> :needs_program
      true -> :needs_key
    end
  end

  @doc """
  Whether a brain, as its setup plan (`component.setup_plan`) answers it,
  runs on a program's own sign-in: every need it requires is a `login`
  need, met by a program row rather than a key.
  """
  @spec signs_in?(map()) :: boolean()
  def signs_in?(plan) when is_map(plan) do
    required = required(plan)
    required != [] and Enum.all?(required, &(&1[:kind] == "login"))
  end

  defp required(plan), do: for(need <- plan[:needs] || [], need[:required] != false, do: need)

  defp head_state(%{consent: %{head_state: state}}), do: state
  defp head_state(_plan), do: nil
end
