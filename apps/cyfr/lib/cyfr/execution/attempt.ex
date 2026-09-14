# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Attempt do
  @moduledoc """
  One process per open execution attempt, holding what CYFR keeps of a
  run between its admission and its terminal write. The attempt's runner
  reaches it only through host calls (`Cyfr.Execution.Host`), which verify
  the call before they reach here.

  `Cyfr.Execution.Admission` opens it once the run's row is admitted,
  registered under the execution's id in `Cyfr.Execution.Attempt.Registry`
  and supervised by `Cyfr.Execution.Attempt.Supervisor`. It holds:

  - the close state (`Cyfr.Execution.Close`): the admitted row, the
    admission context and the node's limits, which only this process
    closes the run with;
  - the claim: the runner that attached (`attach/2`) and the nonces its
    calls have presented;
  - the masking set: the vault fields unsealed at attach, and every OAuth
    access token it dispenses;
  - the run's emitter (`Cyfr.Execution.Emit`): its stream, the root whose
    emit budget it draws on, the authority its events are attributed by,
    and the text it holds back;
  - the context a guest's calls run in (the admission context on the guest
    plane), the node's reference, the need its edge was reached through
    and its limits.

  Its calls are serialized, so a token is either in the masking set before
  the run closes or is never dispensed, and a close waits for an emit in
  flight. A close sends the emitter's held text, masked, then runs
  `Cyfr.Execution.Close` in this process with the full set, tells the
  waiter (`await/2`) the result, answers the runner and stops: what it
  held goes with it.

  It stops without closing the run, sending nothing it held, when its
  opener exits, when the waiter abandons it (`abandon/1`), and when a call
  finds the attempt no longer holds its row: another attempt took it over,
  it was cancelled or it lapsed. A waiter whose attempt stops that way
  closes the run lost (`await/2`, `Cyfr.Execution.Close.lost/1`), which
  writes nothing over a row the attempt no longer holds.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Cyfr.Authority
  alias Cyfr.Authority.Blob.Edge
  alias Cyfr.Delta
  alias Cyfr.Execution.{Close, Emit, Outcome}
  alias Sanctum.Context

  @registry __MODULE__.Registry
  @supervisor __MODULE__.Supervisor

  # A provider name is guest input that reaches a telemetry tag and a log
  # line; a real one is a short identifier.
  @provider_max 128

  # How long a presented nonce is remembered: twice the window a host call's
  # timestamp must fall within, so a replay inside that window is refused.
  @nonce_ttl_ms 60_000

  @enforce_keys [
    :execution_id,
    :attempt,
    :fence,
    :ctx,
    :authority,
    :component_ref,
    :limits,
    :emit,
    :close,
    :owner,
    :waiter
  ]
  defstruct @enforce_keys ++ [:need, :claimed_by, secrets: %{}, tokens: [], nonces: %{}]

  @typedoc "A verified host call's header fields (`Cyfr.WorkerAuth.host_call/0`)."
  @type caller :: Cyfr.WorkerAuth.host_call()

  @typedoc "An operation a runner calls on its attempt once it has attached."
  @type op ::
          {:complete, Outcome.t()}
          | {:fail, Outcome.t()}
          | {:push_deltas, [Delta.t()]}
          | {:oauth_token, String.t()}
          | {:take_rate, String.t()}

  @doc """
  Open the attempt of an admitted execution. The calling process is its
  waiter (`await/2`), and the attempt stops when it exits.

  Required options: `:execution_id`, `:attempt` (the attempt id that owns
  the row), `:ctx` (the admission context), `:authority`, `:component_ref`
  (the node's reference, which keys its `oauth:` rate) and `:close` (the
  run's close state). Optional: `:fence` (default 1), `:need` (the need
  its edge was reached through), `:limits` (default the authority's node
  limits), `:stream_id` (the stream its guest's events go on, default the
  execution's), `:budget_id` (the root whose emit budget they draw on,
  default the execution's) and `:step_spans`.

  Answers `{:error, {:already_started, pid}}` when the execution already
  has an open attempt.
  """
  @spec open(keyword()) :: {:ok, pid()} | {:error, term()}
  def open(opts) when is_list(opts) do
    opts =
      Keyword.merge(opts,
        owner: self(),
        callers: [self() | Process.get(:"$callers", [])],
        logger: Cyfr.LoggerContext.capture()
      )

    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :execution_id)))
  end

  @doc "The process of the open attempt of `execution_id`, or nil."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(execution_id) when is_binary(execution_id) do
    case Registry.lookup(@registry, execution_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Attach the caller's runner, whose claim on the attempt row is written
  (`Arca.ExecutionAttempts.claim/4`), and answer the fields the run's vault
  edge projects: an empty map when it grants none.

  The first attach unseals the edge while its consent is still the
  profile's head. A selection the loader could not resolve, a consent that
  moved and an edge whose material cannot be produced each close the run
  failed as `{:setup_required, payload}`, which is answered. An attach by
  the runner already attached answers the same fields; one by any other
  runner is `:replayed`. A caller naming another attempt or fence, or an
  attempt that is not open, is `:lost`.
  """
  @spec attach(String.t(), caller()) ::
          {:ok, %{optional(String.t()) => String.t()}}
          | {:error, :lost | :replayed | {:setup_required, map()}}
  def attach(execution_id, caller) when is_binary(execution_id) and is_map(caller) do
    call(execution_id, {:attach, caller})
  end

  @doc """
  Run `op` for the caller's runner. Before it runs, the caller must be the
  attached runner at this attempt and fence, its nonce must not have been
  presented before, and the attempt row must still be held by it
  (`Arca.ExecutionAttempts.held?/4`). A caller that fails the first two is
  `:lost`; a row no longer held is `:lost` and stops the attempt; a store
  that cannot answer is `:unavailable`.

  - `{:complete, outcome}` closes the run with the outcome's output:
    `{:ok, masked_output}`, or `{:error, {:failed, message}}` when the close
    recorded a failure instead.
  - `{:fail, outcome}` closes the run failed with the outcome's error: `:ok`.
  - `{:push_deltas, deltas}` emits each delta's event on the attempt's
    stream, masked with its set: `{:ok, replies}`, one reply per delta, the
    JSON a guest's `emit` returns. A delta naming another attempt is
    refused in its reply.
  - `{:oauth_token, provider}` dispenses a token from the edge's vault
    resource, charged to the node's `oauth:` rate and added to the masking
    set before it is answered: `{:ok, token}`, or
    `{:error, {:guest_error, "oauth_error", sentence}}` naming the shape of
    what went wrong, never the material involved.
  - `{:take_rate, bucket}` takes one request from the node's consented rate
    for `bucket`, which must be `"http:"` followed by the node's reference:
    `:ok`, or `{:error, {:guest_error, "rate_limited", sentence}}`.

  An outcome or delta naming another attempt than the caller's is refused
  without closing anything.
  """
  @spec call(String.t(), caller(), op()) :: term()
  def call(execution_id, caller, op) when is_binary(execution_id) and is_map(caller) do
    call(execution_id, {:call, caller, op})
  end

  @doc """
  Wait, in the process that opened it, for the attempt `pid` to close its
  run, and answer the run's result: `{:ok, result}` or `{:error, reason}`
  as `Cyfr.Execution.Close` answered. An attempt that stops without
  closing its run is closed lost with `close` (`Cyfr.Execution.Close.lost/1`).
  """
  @spec await(pid(), Close.t()) :: {:ok, map()} | {:error, term()}
  def await(pid, %Close{} = close) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      {__MODULE__, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        Close.lost(close)
    end
  end

  @doc """
  Stop the attempt of `execution_id` without closing its run, for a waiter
  whose runner could not run it. It sends nothing it held.
  """
  @spec abandon(String.t()) :: :ok
  def abandon(execution_id) when is_binary(execution_id) do
    case call(execution_id, :abandon) do
      {:error, :lost} -> :ok
      :ok -> :ok
    end
  end

  defp call(execution_id, message) do
    GenServer.call(via(execution_id), message, :infinity)
  catch
    :exit, _reason -> {:error, :lost}
  end

  defp via(execution_id), do: {:via, Registry, {@registry, execution_id}}

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    # The opener's callers, so its database sandbox allowance covers the
    # writes and reads made here.
    Process.put(:"$callers", Keyword.fetch!(opts, :callers))
    Cyfr.LoggerContext.restore(Keyword.fetch!(opts, :logger))

    execution_id = Keyword.fetch!(opts, :execution_id)
    authority = Keyword.fetch!(opts, :authority)
    ctx = Context.enter_guest(Keyword.fetch!(opts, :ctx))
    owner = Keyword.fetch!(opts, :owner)

    state = %__MODULE__{
      execution_id: execution_id,
      attempt: Keyword.fetch!(opts, :attempt),
      fence: Keyword.get(opts, :fence, 1),
      ctx: ctx,
      authority: authority,
      component_ref: Keyword.fetch!(opts, :component_ref),
      need: Keyword.get(opts, :need),
      limits: Keyword.get_lazy(opts, :limits, fn -> Authority.limits(authority) end),
      emit:
        Emit.new(Keyword.get(opts, :stream_id, execution_id),
          ctx: ctx,
          authority: authority,
          budget_id: Keyword.get(opts, :budget_id, execution_id),
          step_spans: Keyword.get(opts, :step_spans)
        ),
      close: Keyword.fetch!(opts, :close),
      owner: Process.monitor(owner),
      waiter: owner
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:attach, caller}, _from, state) do
    cond do
      not names_attempt?(state, caller) ->
        {:reply, {:error, :lost}, state}

      state.claimed_by == caller.runner ->
        {:reply, {:ok, state.secrets}, state}

      is_binary(state.claimed_by) ->
        {:reply, {:error, :replayed}, state}

      true ->
        unseal(state, caller)
    end
  end

  def handle_call({:call, caller, op}, _from, state) do
    with :ok <- claimant(state, caller),
         {:ok, noted} <- fresh_nonce(state, caller) do
      case held(caller) do
        :ok -> run(op, noted)
        :gone -> {:stop, :normal, {:error, :lost}, noted}
        :unavailable -> {:reply, {:error, :unavailable}, noted}
      end
    else
      :lost -> {:reply, {:error, :lost}, state}
    end
  end

  def handle_call(:abandon, _from, state), do: {:stop, :normal, :ok, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{owner: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Attach
  # ---------------------------------------------------------------------------

  # Credentials come only from the current edge's vault resource, projected
  # by the vault reader, while the consent is still the profile's head.
  defp unseal(state, caller) do
    case fetch_secrets(state) do
      {:ok, secrets} ->
        {:reply, {:ok, secrets}, %{state | claimed_by: caller.runner, secrets: secrets}}

      {:setup_required, reason} ->
        typed = {:setup_required, setup_payload(state, reason)}

        close_run(state, fn _ -> {:error, typed} end, fn -> Close.fail(state.close, [], typed) end)

      {:raised, message} ->
        close_run(state, fn _ -> {:error, :lost} end, fn ->
          Close.fail(state.close, [], message)
        end)
    end
  end

  defp fetch_secrets(%__MODULE__{authority: authority, close: close}) do
    case authority do
      %Authority{resources: %Edge{vault: %{via: via}}} ->
        {:setup_required, {:selection_unbound, via.label}}

      %Authority{resources: %Edge{vault: %{} = vault}} ->
        if Sanctum.Consent.Loader.pinned_intact?(close.ctx, authority) do
          case Sanctum.VaultReader.fetch(close.ctx, vault) do
            {:ok, secrets} -> {:ok, secrets}
            {:error, reason} -> {:setup_required, reason}
          end
        else
          {:setup_required, :consent_moved}
        end

      _ ->
        {:ok, %{}}
    end
  rescue
    exception -> {:raised, Close.exception_message(exception, __STACKTRACE__)}
  end

  defp setup_payload(state, reason) do
    %{
      profile_id: state.authority.profile_id,
      node_ref: state.component_ref,
      need: state.need || "",
      reason: Close.setup_reason(reason)
    }
  end

  # ---------------------------------------------------------------------------
  # Calls
  # ---------------------------------------------------------------------------

  defp claimant(state, caller) do
    if names_attempt?(state, caller) and state.claimed_by == caller.runner,
      do: :ok,
      else: :lost
  end

  defp names_attempt?(state, caller) do
    caller.execution_id == state.execution_id and caller.attempt == state.attempt and
      caller.fence == state.fence
  end

  defp fresh_nonce(state, %{nonce: nonce, ts: ts}) do
    now = System.system_time(:millisecond)
    nonces = Map.reject(state.nonces, fn {_nonce, seen} -> now - seen > @nonce_ttl_ms end)

    if Map.has_key?(nonces, nonce),
      do: :lost,
      else: {:ok, %{state | nonces: Map.put(nonces, nonce, max(ts, now))}}
  end

  defp held(caller) do
    case Arca.ExecutionAttempts.held?(
           caller.athanor_id,
           caller.attempt,
           caller.fence,
           caller.runner
         ) do
      true -> :ok
      false -> :gone
      {:error, _reason} -> :unavailable
    end
  end

  defp run({:complete, %Outcome{status: :completed} = outcome}, state) do
    if names_outcome?(state, outcome) do
      secrets = masking_set(state)

      close_run(state, &completed_answer/1, fn ->
        Close.complete(state.close, secrets, outcome.output, %{})
      end)
    else
      refuse_outcome(state)
    end
  end

  defp run({:fail, %Outcome{status: :failed} = outcome}, state) do
    if names_outcome?(state, outcome) do
      close_run(state, fn _result -> :ok end, fn ->
        Close.fail(state.close, masking_set(state), outcome.error)
      end)
    else
      refuse_outcome(state)
    end
  end

  defp run({:push_deltas, deltas}, state) do
    {replies, emit} =
      Enum.map_reduce(deltas, state.emit, fn delta, emit -> emit_delta(state, emit, delta) end)

    {:reply, {:ok, replies}, %{state | emit: emit}}
  end

  defp run({:oauth_token, provider}, state) do
    provider = bound_provider(provider)

    case check_dispense_rate(state) do
      :ok ->
        {reply, state} = dispense(state, provider)
        {:reply, reply, state}

      {:error, message} ->
        {:reply, oauth_refusal(message), state}
    end
  end

  defp run({:take_rate, bucket}, state) do
    {:reply, take_rate(state, bucket), state}
  end

  defp run(_op, state), do: {:reply, {:error, :lost}, state}

  defp names_outcome?(state, %Outcome{} = outcome) do
    outcome.execution_id == state.execution_id and outcome.attempt == state.attempt and
      outcome.fence == state.fence
  end

  defp refuse_outcome(state) do
    Logger.error(
      "[Cyfr.Execution.Attempt] #{state.execution_id} refused an outcome naming another attempt"
    )

    {:reply, {:error, :lost}, state}
  end

  # A close sends what the emitter holds, masked with the set as it stands,
  # before the terminal row is written; the waiter hears the result before
  # the runner is answered and the attempt stops.
  defp close_run(state, answer, close) do
    result =
      try do
        _flushed = Emit.flush(state.emit, masking_set(state))
        close.()
      rescue
        exception ->
          Close.fail(
            state.close,
            masking_set(state),
            Close.exception_message(exception, __STACKTRACE__)
          )
      end

    send(state.waiter, {__MODULE__, self(), result})
    {:stop, :normal, answer.(result), state}
  end

  defp completed_answer({:ok, %{output: output}}), do: {:ok, output}

  defp completed_answer({:error, message}) when is_binary(message),
    do: {:error, {:failed, message}}

  defp completed_answer({:error, _typed}), do: {:error, {:failed, "Execution failed"}}

  defp emit_delta(state, emit, %Delta{} = delta) do
    if delta.execution_id == state.execution_id and delta.attempt == state.attempt and
         delta.fence == state.fence do
      Emit.emit(emit, delta.event, masking_set(state))
    else
      {emit_failed(), emit}
    end
  rescue
    exception ->
      Logger.error(
        "[Cyfr.Execution.Attempt] #{state.execution_id} emit raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {emit_failed(), emit}
  end

  defp emit_failed, do: Cyfr.WitResponse.encode_error(:dispatch_error, "The emit call failed.")

  defp masking_set(state), do: Map.values(state.secrets) ++ state.tokens

  # Each HTTP request draws on the node's `http:` bucket under its consented
  # limit; a limiter that cannot answer refuses.
  defp take_rate(state, "http:" <> ref = bucket) when ref == state.component_ref do
    case Cyfr.Execution.Rates.check(state.ctx.athanor_id, bucket, %{
           rate_limit: state.limits.rate_limit
         }) do
      {:ok, _remaining} ->
        :ok

      {:error, :rate_limited, retry_after} ->
        rate_refusal("HTTP egress rate limit exceeded; retry in #{retry_after}ms")

      {:error, :missing_tenant} ->
        rate_refusal("HTTP egress refused: no resolved athanor")
    end
  catch
    :exit, _reason -> rate_refusal("HTTP egress refused: rate limiter unavailable")
  end

  defp take_rate(_state, _bucket),
    do: rate_refusal("HTTP egress refused: the rate bucket is not this component's")

  defp rate_refusal(message), do: {:error, {:guest_error, "rate_limited", message}}

  defp oauth_refusal(message), do: {:error, {:guest_error, "oauth_error", message}}

  # Token requests are metered under their own `oauth:` bucket, apart from
  # HTTP egress; a limiter that cannot answer refuses the dispense.
  defp check_dispense_rate(state) do
    case Cyfr.Execution.Rates.check(
           state.ctx.athanor_id,
           "oauth:" <> state.component_ref,
           %{rate_limit: state.limits.rate_limit}
         ) do
      {:ok, _remaining} ->
        :ok

      {:error, :rate_limited, retry_after} ->
        {:error, "token dispense rate limit exceeded; retry in #{retry_after}ms"}

      {:error, :missing_tenant} ->
        {:error, "token dispense refused: no resolved athanor"}
    end
  catch
    :exit, _reason -> {:error, "token dispense refused: rate limiter unavailable"}
  end

  defp dispense(state, provider) do
    start_time = System.monotonic_time(:millisecond)

    case resolve_token(state, provider) do
      {:ok, token} ->
        token_request(state, provider, start_time, %{status: :ok})
        {{:ok, token}, %{state | tokens: [token | state.tokens]}}

      {:error, reason} ->
        message = refusal_message(reason)

        token_request(state, provider, start_time, %{
          status: :error,
          reason: String.slice(message, 0, 100)
        })

        {oauth_refusal(message), state}
    end
  end

  # The token comes from the current edge's vault resource through the
  # vault reader; an edge without one dispenses nothing.
  defp resolve_token(%__MODULE__{authority: %Authority{resources: resources}} = state, provider) do
    case resources do
      %Edge{vault: %{} = vault} ->
        Sanctum.VaultReader.oauth_token(state.ctx, vault, provider)

      _ ->
        {:error, "no vault resource granted on this edge"}
    end
  rescue
    exception ->
      Logger.error(
        "[Cyfr.Execution.Attempt] #{state.execution_id} token dispense raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, :resolver_unavailable}
  catch
    _kind, _value -> {:error, :resolver_unavailable}
  end

  defp token_request(state, provider, start_time, metadata) do
    :telemetry.execute(
      [:cyfr, :opus, :oauth, :token_request],
      %{duration_ms: System.monotonic_time(:millisecond) - start_time},
      Map.merge(%{component_ref: state.component_ref, provider: provider}, metadata)
    )
  end

  defp bound_provider(provider) when is_binary(provider),
    do: binary_part(provider, 0, min(byte_size(provider), @provider_max))

  # One sentence per shape. The vault reader's reasons name what went wrong
  # and sometimes quote the material that did — `{:invalid_payload, payload}`
  # carries the payload itself — so the guest is told the shape of the
  # failure and never its contents.
  defp refusal_message(reason) when is_binary(reason), do: reason
  defp refusal_message(:anonymous_denied), do: "anonymous callers may not dispense tokens"
  defp refusal_message(:binding_mismatch), do: "the credential no longer matches its consent"
  defp refusal_message(:unseal_failed), do: "the credential could not be unsealed"
  defp refusal_message(:no_oauth_material), do: "this credential carries no OAuth material"
  defp refusal_message(:resolver_unavailable), do: "the credential store is unavailable"
  defp refusal_message({:entry_unavailable, status}), do: "the credential is #{status}"

  defp refusal_message({:provider_mismatch, provider}),
    do: "this credential is not for #{bound_provider(provider)}"

  defp refusal_message({:scope_projection_unsatisfiable, _scopes}),
    do: "the granted scopes do not cover this request"

  defp refusal_message(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp refusal_message({tag, _detail}) when is_atom(tag), do: refusal_message(tag)
  defp refusal_message(_other), do: "the token could not be dispensed"
end
