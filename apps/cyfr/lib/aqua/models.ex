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
      and bound to the key the crew's grant runs it with, or, for a brain
      that is a program, the program row of its name standing
      (`t:status/0`);
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

    * `:ready` — the crew's grant runs it with a bound key;
    * `:needs_key` — a key to connect;
    * `:needs_grant` — the person's grant of the brain is all it asks, as
      Aqua's setup reads it (`t:provider/0`): a brain that needs nothing
      else;
    * `:consent_stale` — Aqua's alone: the crew's grant no longer covers
      what the crew may use (Aqua's tools, or the brains and hands it
      names, changed since it was granted), so every member runs again
      once the person grants it again;
    * `:consent_damaged`, `:consent_unavailable` — the brain's own grant,
      or for Aqua the crew's, is damaged, or the store could not answer
      it;
    * `:missing` — the athanor's catalysts, read, hold no such model, or
      its setup plan answers that the registry holds no such component;
    * `:model_unavailable` — the athanor's catalysts could not be read,
      or its setup plan was refused for any other reason, so whether it is
      installed is not known.

  A brain that is a program (the agent's `"program"`, the name of one of
  the athanor's program rows) reads on the row of that name alone, since
  each of its turns is admitted by that turn's own `program.start` step:
  `:ready` when the row stands as a brain's (the athanor's own, a driven
  program with a kept folder whose command starts with a brain's driver,
  enabled), which is signed in when the program says so;
  `:program_unfit` when it is not a program a brain runs in (Aqua's
  browser and a bare harness among them), `:program_disabled` when it is
  turned off, `:program_missing` when the athanor has no row of that
  name, the one state its install is offered in, and `:model_unavailable`
  when the store could not answer; each carries the name the agent names.
  """
  @type status ::
          {:ready
           | :needs_key
           | :needs_grant
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
  # The brains' drivers whose harness cannot start read-only in the box
  # (`holds_read_only?/1`).
  @unheld_drivers ~w(cyfr-codex)
  # The crew's one grant, which runs every member's brain
  # (`Compendium.AgentSource`).
  @grant Prima.AgentRef.soul_ref()

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
  included, declares none (a program's are its listing's,
  `program_listing/2`); a catalyst the athanor does not hold is
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

  @doc """
  What the program a program brain names lists, read as the person at the
  Aqua page from the harness of the row of that name (`program/2`,
  `Opus.Brain.models/2`): `{:ok, %{models: [%{id, name}], efforts:
  [effort]}}`, the models its `model` may name and the efforts its
  `effort` option may take. A name with no row, or a row that does not
  stand as a brain's, is `program/2`'s refusal, and one whose harness did
  not list them is the holder's (`{:refused, sentence}` among them); a
  turn's context is refused, since only a person at a screen lists.
  """
  @spec program_listing(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def program_listing(%Context{} = ctx, %{"program" => name}) when is_binary(name) do
    with {:ok, %{row: row_id}} <- program(ctx, name), do: Opus.Brain.models(ctx, row_id)
  end

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
  reason}` with `kind` the credential kind (`qualifier` the provider its
  key is for), or nil for a brain that needs nothing — its `state` as its
  own consent reads it (`:needs_grant` for a brain never granted, or whose
  grant was revoked, that needs nothing else of the person: no required
  need), and `shared`, `%{owner, person_daily}`
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

      {:ok,
       rows
       |> newest_speaking()
       |> Enum.map(fn {provider, ref} -> provider(ctx, provider, ref, shares) end)
       |> Enum.sort_by(&{is_nil(&1.shared), &1.provider})}
    end
  end

  defp provider(ctx, provider, ref, shares) do
    case Aqua.Ops.call_tool("component", ctx, %{"action" => "setup_plan", "reference" => ref}) do
      {:ok, plan} ->
        %{
          provider: provider,
          ref: ref,
          need: need_of(plan),
          state: plan_state(plan, ref),
          shared: shared(plan, shares)
        }

      {:error, _unread} ->
        %{provider: provider, ref: ref, need: nil, state: :model_unavailable, shared: nil}
    end
  end

  defp need_of(plan) do
    case for(need <- plan[:needs] || [], need[:required] != false, do: need) do
      [need | _] -> Map.take(need, [:name, :kind, :qualifier, :reason])
      [] -> nil
    end
  end

  defp plan_state(%{ready: true}, _ref), do: :ready

  defp plan_state(plan, ref) do
    case unready(plan, ref) do
      {:connect, _} -> connect_state(plan)
      {state, _} -> state
    end
  end

  # A brain with no grant to stand on, never made or revoked, and no
  # required need: the person's grant is all it asks, so no key is offered.
  # A required need already met before a revocation is not told apart
  # here, since an ungranted plan carries no binding to read it from. On
  # a plan that reads ready, as an agent's status reads it once the
  # agent's edge binds nothing, the grant that waits is the agent's own.
  defp grant_only?(plan),
    do: head_state(plan) in ["missing", "revoked"] and is_nil(need_of(plan))

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
  catalyst resolves to and whether it is connected —
  `%{name => t:status/0}`: `{:ready | :needs_key | :needs_grant |
  :consent_stale | :consent_damaged | :consent_unavailable,
  resolved_ref}`, or `{:missing | :model_unavailable,
  catalyst_ref}` — or, for a brain that is a program, how its row stands
  (`t:status/0`). An agent that names no brain has no entry. A crew
  member holds no consent of its own: it is ready when its brain is
  connected, the brain's own grant binding its key and the crew's one
  grant (`Compendium.AgentSource`) running it with that key, so making a
  member on a connected brain, or choosing it as Aqua's, asks nothing.

  A brain is connected on a bound need of either kind: a key the
  catalyst's requests carry, or a program row whose folder it runs its
  program in (`Sanctum.Mount`) — the setup plan and the edge read both
  the same way. The brain's own grant that is damaged, or that the store
  could not answer, is `:consent_damaged` or `:consent_unavailable`,
  never a key to connect over a consent that exists. The crew's grant is
  read once, as a turn loads it: where it loads, a brain its edge binds
  no key on is one to connect; where it does not, Aqua reads why
  (`Aqua.ConsentStatus.classify_refusal/1`: a stale grant is
  `:consent_stale`, a grant to give again, and damage or an outage as
  above), which is said once, on Aqua, and never on a member. A catalyst
  listing that cannot be read is not an empty one, and a setup plan
  refused for any reason but the component's absence
  (`{:not_found, {:component, _}}`,
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
    brains = for %{"name" => name} = agent <- agents, is_binary(name), do: {name, brain_of(agent)}

    # The crew's one grant, loaded once for every catalyst brain given.
    grant =
      if Enum.any?(brains, &match?({_name, {:catalyst, _}}, &1)),
        do: Opus.authority_for(ctx, :default, @grant)

    for {name, brain} <- brains, brain != nil, into: %{} do
      case brain do
        {:program, id} -> {name, program_status(ctx, id)}
        {:catalyst, ref} -> {name, catalyst_status(ctx, listing, grant, name, ref)}
      end
    end
  end

  # The brain an agent names: its program, by the row's name, or its
  # catalyst. A file names one at most (`Compendium.AquaAgent.check_brain/1`),
  # and a map that carries no program names its catalyst.
  defp brain_of(%{"program" => name}) when is_binary(name) and name != "",
    do: {:program, name}

  defp brain_of(%{"catalyst_ref" => ref}) when is_binary(ref) and ref != "", do: {:catalyst, ref}
  defp brain_of(_agent), do: nil

  # Every status names the program as the agent does: a row of that name
  # that stands unfit, disabled or unread is never one that is missing.
  defp program_status(ctx, name) do
    case program(ctx, name) do
      {:ok, _row} -> {:ready, name}
      {:error, {state, _name}} -> {state, name}
      {:error, :program_missing} -> {:program_missing, name}
      {:error, :unavailable} -> {:model_unavailable, name}
    end
  end

  @doc """
  The program row a program brain's configuration names, by its name,
  unique in the athanor, as it stands now (`suited/1`): what a turn
  resolves once before it pins the row's id, and what every reader of
  an agent's readiness reads. `{:error, :program_missing}` when the
  athanor has no row of that name, which is the one state that offers
  to install it; `{:error, :unavailable}` when the store cannot answer.
  """
  @spec program(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def program(%Context{} = ctx, name) when is_binary(name),
    do: suited(Arca.McpServerStorage.get(Context.actor(ctx), name))

  @doc """
  The program row a turn pinned, by its id (`Arca.TurnStorage.pin_program/4`),
  as it stands now (`suited/1`): a pinned turn, recovery included, reads
  its row by this and never resolves its agent's program name again, so
  a row replaced under the same name is the next turn's.
  """
  @spec pinned_program(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def pinned_program(%Context{} = ctx, row_id) when is_binary(row_id),
    do: suited(Arca.McpServerStorage.get_by_id(Context.actor(ctx), row_id))

  # A row a brain runs in: `{:ok, %{row, epoch, name, driver}}` for an
  # enabled driven program with a kept folder whose command starts with a
  # brain's driver (`Arca.McpServerStorage.driver/1`); else
  # `{:error, {:program_unfit, name}}` for any other row, Aqua's browser
  # and a bare harness among them, `{:error, {:program_disabled, name}}`
  # for a fit one that is disabled, `{:error, :program_missing}` or
  # `{:error, :unavailable}`. The holder checks the row again as it writes
  # (`Opus.Brain`).
  defp suited({:ok, %{transport: "program", mark: "driven", home: "kept"} = row}) do
    case {Arca.McpServerStorage.driver(row), row.enabled} do
      {nil, _enabled} ->
        {:error, {:program_unfit, row.name}}

      {driver, true} ->
        {:ok, %{row: row.id, epoch: row.epoch, name: row.name, driver: driver}}

      {_driver, _disabled} ->
        {:error, {:program_disabled, row.name}}
    end
  end

  defp suited({:ok, row}), do: {:error, {:program_unfit, row.name}}
  defp suited({:error, :not_found}), do: {:error, :program_missing}
  defp suited({:error, _unanswered}), do: {:error, :unavailable}

  # A brain is ready when its own profile binds what it needs AND the
  # crew's grant selects that profile on its edge to the catalyst — what
  # every member actually runs it with, resolved as a turn would resolve
  # it. A bound key the grant's edge does not select is still one to
  # connect.
  defp catalyst_status(_ctx, {:error, _unread}, _grant, _name, ref),
    do: {:model_unavailable, ref}

  defp catalyst_status(ctx, {:ok, listing}, grant, name, ref) do
    case Aqua.AgentConfig.resolve_catalyst(listing, ref) do
      {:ok, resolved} -> planned_status(ctx, grant, name, ref, resolved)
      {:error, _no_such_catalyst} -> {:missing, ref}
    end
  end

  # The setup plan's refusal is classed on its typed reason: the
  # registry's answer that it holds no such component is an absence, and
  # every other refusal (a store that could not answer, which the
  # component domain answers as a sentence, a damaged row, a timeout, a
  # forbidden call, anything else) leaves whether it is installed unknown.
  defp planned_status(ctx, grant, name, ref, resolved) do
    case Aqua.Ops.call_tool("component", ctx, %{
           "action" => "setup_plan",
           "reference" => resolved
         }) do
      {:ok, plan} ->
        case plan_state(plan, resolved) do
          :ready -> granted_status(grant, name, ref, resolved, connect_state(plan))
          state -> {state, resolved}
        end

      {:error, {:not_found, {:component, _reference}}} ->
        {:missing, ref}

      {:error, _refused} ->
        {:model_unavailable, ref}
    end
  end

  # The crew's grant, loaded as a turn would load it: where its edge to
  # the brain binds nothing, connecting the brain is what it asks
  # (`connect_state/1`). A grant that does not load is Aqua's to say,
  # read through `Aqua.ConsentStatus.classify_refusal/1`: damage (the
  # grant's head, a lender, a stored grant that fails its checks), an
  # outage, or a grant whose shape moved since it was given, never a key
  # to connect, and a grant there is none of is the brain's to connect. A
  # crew member reads its brain alone, which its own grant answers: it
  # holds no consent, and the grant's state is said once, on Aqua.
  defp granted_status({:ok, authority}, _name, catalyst_ref, resolved, connect) do
    if lent?(authority, @grant, catalyst_ref),
      do: {:ready, resolved},
      else: {connect, resolved}
  end

  defp granted_status({:error, reason}, name, _catalyst_ref, resolved, connect) do
    if Prima.AgentRef.soul?(name) do
      case Aqua.ConsentStatus.classify_refusal(reason) do
        {:ok, :stale} -> {:consent_stale, resolved}
        {:error, :corrupt} -> {:consent_damaged, resolved}
        {:error, :unavailable} -> {:consent_unavailable, resolved}
        _absent_or_forbidden -> {connect, resolved}
      end
    else
      {:ready, resolved}
    end
  end

  # A bound vault is an entry or a key provided alike
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
  # and every agent's status read: its grant alone (`grant_only?/1`), else
  # a key.
  defp connect_state(plan), do: if(grant_only?(plan), do: :needs_grant, else: :needs_key)

  @doc """
  Whether a read-only member's brain that is a program row can be kept
  read-only, by its row's driver, which must be one that starts its
  harness read-only; a catalyst's brain runs no program, so CYFR's mode
  reaches every call it makes. Codex's
  sandbox cannot start in the box, so its driver refuses a read-only
  start (`cyfr-codex`), and a member on such a row is refused before it.
  The row's driver is the one `Arca.McpServerStorage.driver/1` names, by
  its name or its installed path. A row whose command reaches a driver
  another way (through `env` or `sh -c`, or from another path) names
  none, so it is no brain's row: it reads unfit, and a turn on it is
  refused before this check is asked (`program/2`), since such a program
  could run but its transcripts could not be forgotten one by one
  (`Opus.Brain`).
  """
  @spec holds_read_only?({:driver, String.t() | nil}) :: boolean()
  def holds_read_only?({:driver, driver}), do: driver not in @unheld_drivers

  @doc """
  The sentence a read-only member whose brain cannot be kept read-only
  (`holds_read_only?/1`) is refused with: as a line in the thread its turn
  never ran in, and beneath the read-only choice on the Aqua page.
  """
  @spec unheld_sentence(String.t(), String.t()) :: String.t()
  def unheld_sentence(title, brain) when is_binary(title) and is_binary(brain),
    do:
      "#{title} can't run read-only: its brain, #{brain}, runs a program CYFR can't keep " <>
        "read-only, so nothing ran. Switch #{title} to auto on the Aqua page to use it."

  @doc """
  Each of `members` (as the `aqua` tool lists them: `name`, `title` and
  a `catalyst_ref` or a `program`) whose brain CYFR cannot keep read-only
  (`holds_read_only?/1`), by name, with the sentence the Aqua page shows
  beneath its closed read-only choice (`unheld_sentence/2`): the program
  row of the name it names, read once each by that name, whose driver
  cannot start its harness read-only. A row that cannot be read leaves
  the member out; its turn checks the brain again before anything runs
  (`Aqua.Loop.Turn`).
  """
  @spec read_only_unheld(Context.t(), [map()]) :: %{String.t() => String.t()}
  def read_only_unheld(%Context{} = ctx, members) when is_list(members) do
    rows =
      for name <- members |> Enum.map(& &1[:program]) |> Enum.uniq(),
          is_binary(name) and name != "",
          {:ok, row} <- [program(ctx, name)],
          into: %{},
          do: {name, row}

    for member <- members,
        brain <- List.wrap(unheld_brain(member, rows)),
        into: %{},
        do: {member.name, unheld_sentence(member[:title] || member.name, brain)}
  end

  defp unheld_brain(%{program: program}, rows) when is_binary(program) do
    with %{name: name, driver: driver} <- rows[program],
         false <- holds_read_only?({:driver, driver}) do
      name
    else
      _held -> nil
    end
  end

  defp unheld_brain(_member, _rows), do: nil

  defp head_state(%{consent: %{head_state: state}}), do: state
  defp head_state(_plan), do: nil
end
