# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Models do
  @moduledoc """
  The assistant's model work over `model/chat@1` (`Prima.Model`, which
  names the contract and reads its envelope):

    * `capabilities/5` — what one model can do, read from its catalyst's
      `describe` and cached under the key the reading ran with;
    * `catalogue/1` — the listing the console's pickers show, every
      installed catalyst that speaks the contract asked for its models;
    * `model_status/2` — whether each agent's model has a key the
      assistant runs it with (`t:status/0`).

  The component facts come from `Compendium.model_catalysts/1`; running a
  catalyst goes through the gate like any other call, under the caller's
  own plane.
  """

  alias Sanctum.Context

  @typedoc """
  A soul's model as `model_status/2` reads it. The first four carry the
  release the soul's ref resolves to; `:missing` and `:model_unavailable`
  carry the ref the soul names, whether or not the listing resolved it:

    * `:ready` — the assistant runs it with a bound key;
    * `:needs_key` — a key to connect;
    * `:consent_damaged`, `:consent_unavailable` — a consent it runs
      under is damaged, or the store could not answer it;
    * `:missing` — the athanor's catalysts, read, hold no such model, or
      its setup plan answers that the registry holds no such component;
    * `:model_unavailable` — the athanor's catalysts could not be read,
      or its setup plan was refused for any other reason, so whether it is
      installed is not known.
  """
  @type status ::
          {:ready
           | :needs_key
           | :consent_damaged
           | :consent_unavailable
           | :missing
           | :model_unavailable, String.t()}

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
  names no window; `{:describe_failed, reason}` when the run failed,
  `reason` `:timeout` when it outran `:timeout`. No error is cached.
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

  defp describe_model(model, run) do
    with {:ok, result} <- ran(run.(%{"operation" => "describe", "params" => %{"model" => model}})),
         {:ok, described} <- described(Prima.Model.decode_envelope(result), model),
         {:ok, window} <- window(described, model) do
      {:ok,
       %{
         context_window: window,
         max_output_tokens: positive(described["max_output_tokens"]),
         max_input_tokens: positive(described["max_input_tokens"]),
         provider_tools: list_of_strings(described["provider_tools"]),
         media_types: list_of_strings(described["media_types"]),
         streaming: described["streaming"] == true,
         default_max_tokens: positive(get_in(described, ["defaults", "max_tokens"]))
       }}
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
  The model listing the console shows: every installed catalyst that
  declares the contract, at its newest version, asked for `models`
  through the catalog (so consent applies: a catalyst with no key answers
  `setup_required` and is listed under `errors`, not `models`).

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

  defp list_models(ctx, ref) do
    run =
      Aqua.Ops.call_tool("execution", ctx, %{
        "action" => "run",
        "reference" => ref,
        "type" => "catalyst",
        "input" => %{"operation" => "models", "params" => %{}}
      })

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

  defp refusal_text(reason), do: Grimoire.render(reason)

  @doc """
  For each soul's catalyst: the installed release it resolves to and
  whether its consent is complete — `%{catalyst_ref => t:status/0}`,
  keyed by the catalyst ref the agent names: `{:ready | :needs_key |
  :consent_damaged | :consent_unavailable, resolved_ref}`, or
  `{:missing | :model_unavailable, catalyst_ref}`. A consent the model
  runs under that is damaged, or that the store could not answer, is
  `:consent_damaged` or `:consent_unavailable`, never a key to connect
  over a consent that exists: the model's own consent, as its setup plan
  reads it, and, once that reads ready, the assistant's own load
  (`Aqua.ConsentStatus.classify_refusal/1`). A catalyst listing that
  cannot be read is not an empty one, and a setup plan refused for any
  reason but the component's absence (`{:not_found, {:component, _}}`,
  `Compendium.Component.resolve_component/2`'s one absence) is not an
  absence: each is `:model_unavailable`, never a model to install.

  A model with no key is the one thing that keeps a fresh athanor's AQUA
  silent, so both the AQUA page and the chat's own empty state ask here.
  """
  @spec model_status(Context.t() | nil, [map()]) :: %{String.t() => status()}
  def model_status(nil, _agents), do: %{}

  def model_status(%Context{} = ctx, agents) when is_list(agents) do
    # The listing's refusal is kept: a listing that cannot be read never
    # resolves a model against no catalysts.
    listing = Aqua.AgentConfig.catalyst_listing(ctx)

    soul_type = Compendium.agent_soul_type()

    agents
    |> Enum.filter(&(&1["type"] == soul_type))
    |> Enum.map(& &1["catalyst_ref"])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Map.new(fn ref -> {ref, catalyst_status(ctx, listing, ref)} end)
  end

  # A model is ready when its own profile binds a key AND the assistant's
  # consent selects that profile on its edge to the catalyst — the key
  # the assistant actually runs it with, resolved as a turn would resolve
  # it. A bound key the assistant's edge does not select is still a key
  # to connect.
  defp catalyst_status(_ctx, {:error, _unread}, ref), do: {:model_unavailable, ref}

  defp catalyst_status(ctx, {:ok, listing}, ref) do
    case Aqua.AgentConfig.resolve_catalyst(listing, ref) do
      {:ok, resolved} -> planned_status(ctx, ref, resolved)
      {:error, _no_such_catalyst} -> {:missing, ref}
    end
  end

  # The setup plan's refusal is classed on its typed reason: the
  # registry's answer that it holds no such component is an absence, and
  # every other refusal (a store that could not answer, which the
  # component domain answers as a sentence, a damaged row, a timeout, a
  # forbidden call, anything else) leaves whether it is installed unknown.
  defp planned_status(ctx, ref, resolved) do
    case Aqua.Ops.call_tool("component", ctx, %{
           "action" => "setup_plan",
           "reference" => resolved
         }) do
      {:ok, plan} ->
        if (plan[:ready] || plan["ready"]) == true,
          do: assistant_status(ctx, ref, resolved),
          else: unready(plan, resolved)

      {:error, {:not_found, {:component, _reference}}} ->
        {:missing, ref}

      {:error, _refused} ->
        {:model_unavailable, ref}
    end
  end

  # The assistant's own load, as a turn would make it, read through
  # `Aqua.ConsentStatus.classify_refusal/1`: a load that refuses for
  # damage (the assistant's head, a lender, a stored grant that fails its
  # checks) or because the store could not answer is said as such, never
  # as a key to connect; every other refusal, and an edge that binds no
  # key, is a key to connect.
  defp assistant_status(ctx, catalyst_ref, resolved) do
    soul = Prima.AgentRef.soul_ref()

    case Crucible.authority_for(ctx, :default, soul) do
      {:ok, authority} ->
        if lent?(authority, soul, catalyst_ref),
          do: {:ready, resolved},
          else: {:needs_key, resolved}

      {:error, reason} ->
        case Aqua.ConsentStatus.classify_refusal(reason) do
          {:error, :corrupt} -> {:consent_damaged, resolved}
          {:error, :unavailable} -> {:consent_unavailable, resolved}
          _absent_stale_or_forbidden -> {:needs_key, resolved}
        end
    end
  end

  defp lent?(authority, soul, catalyst_ref) do
    case Prima.Authority.Blob.lookup_edge(authority.policy, soul, catalyst_ref, "") do
      {:ok, edge} -> Prima.Authority.Blob.bound_vault?(edge.vault)
      _no_edge -> false
    end
  end

  # A plan that is not ready because the model's own consent is damaged,
  # or the store could not answer it, is no key to connect: connecting
  # cannot repair a consent that exists. A head never granted, or no
  # profile, is.
  defp unready(plan, resolved) do
    case head_state(plan) do
      "damaged" -> {:consent_damaged, resolved}
      "unavailable" -> {:consent_unavailable, resolved}
      _missing_or_ungranted -> {:needs_key, resolved}
    end
  end

  defp head_state(plan) do
    case plan[:consent] || plan["consent"] do
      %{} = consent -> consent[:head_state] || consent["head_state"]
      _none -> nil
    end
  end
end
