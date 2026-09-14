# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Attempt do
  @moduledoc """
  One process per open execution attempt, holding what CYFR hands to the
  run until the run closes.

  `Cyfr.Execution.Admission` opens it once the run's vault fields are
  unsealed, registered under the execution's id in
  `Cyfr.Execution.Attempt.Registry` and supervised by
  `Cyfr.Execution.Attempt.Supervisor`. It holds:

  - the masking set: the unsealed field values, and every OAuth access
    token `dispense_oauth/2` hands out;
  - the run's emitter (`Cyfr.Execution.Emit`): its stream, the root whose
    emit budget it draws on, the authority its events are attributed by,
    and the text it holds back;
  - the context a guest's calls run in (the admission context on the guest
    plane), the node's reference and limits.

  Its calls are serialized, so a token is either in the masking set before
  the run closes or is never dispensed, and `complete/4` and `fail/3` wait
  for an emit in flight. Each of them sends the emitter's held text,
  masked, then runs `Cyfr.Execution.Close` in this process with the full
  set, answers, and stops: what it held goes with it. An attempt whose
  opener exits stops at once, sending nothing it held.

  Every function names the attempt by its execution id. One whose attempt
  is not open answers as documented on it: an emit or a dispense is refused
  to the guest, and a close answers `:lost`.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Cyfr.Authority
  alias Cyfr.Execution.{Close, Emit}
  alias Sanctum.Context

  @registry __MODULE__.Registry
  @supervisor __MODULE__.Supervisor

  # A provider name is guest input that reaches a telemetry tag and a log
  # line; a real one is a short identifier.
  @provider_max 128

  @enforce_keys [:execution_id, :ctx, :authority, :component_ref, :limits, :emit, :owner]
  defstruct [
    :execution_id,
    :attempt,
    :ctx,
    :authority,
    :component_ref,
    :limits,
    :emit,
    :owner,
    secrets: [],
    tokens: []
  ]

  @doc """
  Open the attempt of an execution, owned by the calling process.

  Required options: `:execution_id`, `:ctx` (the admission context),
  `:authority`, `:component_ref` (the node's reference, which keys its
  `oauth:` rate). Optional: `:attempt` (the attempt id that owns the row),
  `:secrets` (the unsealed fields, name to value), `:limits` (default the
  authority's node limits), `:stream_id` (the stream its guest's events go
  on, default the execution's), `:budget_id` (the root whose emit budget
  they draw on, default the execution's) and `:step_spans`.

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
  Emit one guest event on the attempt's stream (`Cyfr.Execution.Emit.emit/3`),
  masked with its set. Answers the JSON the guest's `emit` returns; an
  attempt that is not open answers a `dispatch_error`.
  """
  @spec emit(String.t(), String.t()) :: String.t()
  def emit(execution_id, json_event) when is_binary(execution_id) and is_binary(json_event) do
    case call(execution_id, {:emit, json_event}) do
      :lost ->
        Logger.warning("[Cyfr.Execution.Attempt] #{execution_id} emit reached no open attempt")
        Cyfr.WitResponse.encode_error(:dispatch_error, "The emit call failed.")

      answer ->
        answer
    end
  end

  @doc """
  Dispense an OAuth access token for `provider` from the attempt's consented
  vault edge, charged to the node's `oauth:` rate, and add it to the
  masking set before answering it.

  Answers `{:ok, token}` or `{:error, sentence}`: a refusal names the shape
  of what went wrong, never the material involved. An attempt that is not
  open refuses.
  """
  @spec dispense_oauth(String.t(), term()) :: {:ok, String.t()} | {:error, String.t()}
  def dispense_oauth(execution_id, provider) when is_binary(execution_id) do
    case call(execution_id, {:dispense_oauth, bound_provider(provider)}) do
      :lost -> {:error, "the credential store is unavailable"}
      answer -> answer
    end
  end

  @doc """
  Close the run of `execution_id` with its `output`: send the text the
  emitter holds, masked, then `Cyfr.Execution.Close.complete/4` with the
  masking set. Answers what that answers, or `:lost` when the attempt is
  not open or ended during the call.
  """
  @spec complete(String.t(), Close.t(), term(), map()) ::
          {:ok, map()} | {:error, term()} | :lost
  def complete(execution_id, %Close{} = close, output, exec_metadata) do
    call(execution_id, {:close, close, {:complete, output, exec_metadata}})
  end

  @doc """
  Close the run of `execution_id` failed with `reason`: send the text the
  emitter holds, masked, then `Cyfr.Execution.Close.fail/3` with the
  masking set. Answers what that answers, or `:lost` when the attempt is
  not open or ended during the call.
  """
  @spec fail(String.t(), Close.t(), term()) :: {:error, term()} | :lost
  def fail(execution_id, %Close{} = close, reason) do
    call(execution_id, {:close, close, {:fail, reason}})
  end

  defp call(execution_id, message) do
    GenServer.call(via(execution_id), message, :infinity)
  catch
    :exit, _reason -> :lost
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
      attempt: Keyword.get(opts, :attempt),
      ctx: ctx,
      authority: authority,
      component_ref: Keyword.fetch!(opts, :component_ref),
      limits: Keyword.get_lazy(opts, :limits, fn -> Authority.limits(authority) end),
      emit:
        Emit.new(Keyword.get(opts, :stream_id, execution_id),
          ctx: ctx,
          authority: authority,
          budget_id: Keyword.get(opts, :budget_id, execution_id),
          step_spans: Keyword.get(opts, :step_spans)
        ),
      owner: Process.monitor(owner),
      secrets: opts |> Keyword.get(:secrets, %{}) |> Map.values()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:emit, json_event}, _from, state) do
    {answer, emit} =
      try do
        Emit.emit(state.emit, json_event, masking_set(state))
      rescue
        exception ->
          Logger.error(
            "[Cyfr.Execution.Attempt] #{state.execution_id} emit raised: " <>
              Exception.format(:error, exception, __STACKTRACE__)
          )

          {Cyfr.WitResponse.encode_error(:dispatch_error, "The emit call failed."), state.emit}
      end

    {:reply, answer, %{state | emit: emit}}
  end

  def handle_call({:dispense_oauth, provider}, _from, state) do
    case check_dispense_rate(state) do
      :ok ->
        {reply, state} = dispense(state, provider)
        {:reply, reply, state}

      {:error, _message} = refused ->
        {:reply, refused, state}
    end
  end

  def handle_call(
        {:close, %Close{record: %{id: id}} = close, how},
        _from,
        %__MODULE__{execution_id: id} = state
      ) do
    secrets = masking_set(state)

    reply =
      try do
        # What the emitter holds goes out before the terminal row is written.
        _flushed = Emit.flush(state.emit, secrets)

        case how do
          {:complete, output, exec_metadata} ->
            Close.complete(close, secrets, output, exec_metadata)

          {:fail, reason} ->
            Close.fail(close, secrets, reason)
        end
      rescue
        exception ->
          Close.fail(close, secrets, Close.exception_message(exception, __STACKTRACE__))
      end

    {:stop, :normal, reply, state}
  end

  def handle_call({:close, %Close{}, _how}, _from, state) do
    Logger.error(
      "[Cyfr.Execution.Attempt] #{state.execution_id} refused a close naming another execution"
    )

    {:reply, :lost, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{owner: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  defp masking_set(state), do: state.secrets ++ state.tokens

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

        {{:error, message}, state}
    end
  end

  # The token comes from the current edge's vault resource through the
  # vault reader; an edge without one dispenses nothing.
  defp resolve_token(%__MODULE__{authority: %Authority{resources: resources}} = state, provider) do
    case resources do
      %Authority.Blob.Edge{vault: %{} = vault} ->
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

  defp bound_provider(other), do: other |> to_string() |> bound_provider()

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
