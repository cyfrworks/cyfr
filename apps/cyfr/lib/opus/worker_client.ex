# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.WorkerClient do
  @moduledoc """
  CYFR's client of one worker service (`Prima.WorkerAPI`) over HTTP, as
  `Prima.WorkerWire` frames it. `Opus.Dispatch` reaches every
  worker service through it, the scripted one of the test suite exactly as
  the runtime.

  Each function takes the worker service's `t:Prima.WorkerAPI.endpoint/0`
  and answers as the `Prima.WorkerAPI` callback of the same name, with two
  refusals of the transport's own:

    * `{:error, :unavailable}` — the worker service could not be reached:
      no connection was made, or its configured id is not one keys derive
      over. Nothing was asked of it.
    * `{:error, :lost}` — the request went out and no readable answer came
      back within `Prima.WorkerAPI.request_timeout_ms/1`: the connection
      timed out or closed, or what came back is not an answer. The worker
      service may have acted.

  A request is a `POST` to the callback's route (`Prima.WorkerWire.worker_route/1`)
  whose body is the JSON `{"v", "op", "args"}` (`Prima.WorkerWire.request_body/2`)
  and whose `x-cyfr-auth` header
  is `Prima.WorkerAuth.request_header/3` over that body, signed with the
  worker service's dispatch key (`Opus.Keys.locus_runtime_key/1`),
  naming the service the request is addressed to and this boot
  (`Prima.Boot.id/0`) as the incarnation presenting it, under a fresh nonce.
  An answer is a `200` read up to `Prima.HostAPI.max_answer_bytes/0` and
  read at this wire's version (`Prima.WorkerWire.read_answer/1`):
  `{"v": 3, "ok": value}` is the callback's success and
  `{"v": 3, "error": name}` naming `malformed` or `not_found` its
  refusal; any other status, an answer without `v` or at another
  version, any other name, or anything else in an answer's place, is a
  lost answer. A lost answer is retried once, with a fresh nonce, when
  `Prima.WorkerAPI.retry/1` allows it (`kill` and `status`), never for
  `start`: its assignment's claim window bounds the worker service, and
  dispatch reconciles against the attempt.

  Two listener refusals are answers. A `start` refused `503`
  `{"v": 3, "error": "no_memory", "held": held}` is `{:error, {:no_memory,
  held}}`: the keeper found no room for its runner, `held`
  (`Prima.LocusPool.read_held/1`) says what holds the memory, and the
  service started nothing; one whose `held` does not read stays lost. And
  a `start` refused `503`
  `{"v": 3, "error": "unavailable", "message": sentence}`, the worker service's
  account of why no runner can take it (its keeper refuses runners,
  `t:Prima.WorkerAPI.refusal/0`), is `{:error, {:unavailable, sentence}}`,
  since the service answers it only once it has decided to start nothing.
  A `503` without a sentence, or with one that is not a refusal's
  (`Prima.WorkerAPI.valid_refusal_message?/1`), stays lost: the listener
  answers it too when its call into the service timed out, after which the
  service may still start the run.
  """

  alias Prima.{HostAPI, WorkerAPI, WorkerAuth, WorkerWire}
  alias Opus.Keys

  @connect_timeout_ms 5_000

  # The refusals a worker service answers at `200`, by name
  # (`tests/fixtures/worker_api.json`): a start's `malformed` and a kill's
  # `not_found`. Its other refusals come at another status, and anything
  # else in an answer's place is a lost answer.
  @refusals %{"malformed" => :malformed, "not_found" => :not_found}

  @typedoc "What the transport itself answers when the worker service did not."
  @type transport_refusal :: :lost | :unavailable

  @doc """
  Start an assignment on `endpoint` (`c:Prima.WorkerAPI.start/3`): `input`
  is the execution's input bytes and `sealed_keys` the attempt's keys
  sealed for that worker service. `{:error, {:unavailable, sentence}}` is
  the worker service's refusal of the start: it started nothing, and
  `sentence` says why.
  """
  @spec start(WorkerAPI.endpoint(), Prima.Assignment.token(), binary(), String.t()) ::
          :ok
          | {:error,
             :malformed
             | :not_found
             | {:unavailable, String.t()}
             | {:no_memory, Prima.LocusPool.held()}
             | transport_refusal()}
  def start(%{id: id, url: url} = endpoint, token, input, sealed_keys)
      when is_binary(id) and is_binary(url) and is_binary(token) and is_binary(input) and
             is_binary(sealed_keys) do
    args = %{"assignment" => token, "input" => input, "sealed_keys" => sealed_keys}

    case request(endpoint, :start, args) do
      {:ok, true} -> :ok
      {:ok, _other} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stop the execution `execution_id` on `endpoint` (`c:Prima.WorkerAPI.kill/1`)."
  @spec kill(WorkerAPI.endpoint(), String.t()) ::
          :ok | {:error, :malformed | :not_found | transport_refusal()}
  def kill(%{id: id, url: url} = endpoint, execution_id)
      when is_binary(id) and is_binary(url) and is_binary(execution_id) do
    case request(endpoint, :kill, %{"execution_id" => execution_id}) do
      {:ok, true} -> :ok
      {:ok, _other} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The state of the worker service at `endpoint` (`c:Prima.WorkerAPI.status/0`),
  read as `Prima.WorkerAPI.read_status/1` reads it: a count for every
  runner state, `tainted` included, the memory bound its runners run
  under and its keeper's refusal, and nothing else. An answer of another
  shape is lost.
  """
  @spec status(WorkerAPI.endpoint()) ::
          {:ok, WorkerAPI.status()} | {:error, :malformed | :not_found | transport_refusal()}
  def status(%{id: id, url: url} = endpoint) when is_binary(id) and is_binary(url) do
    with {:ok, answer} <- request(endpoint, :status, %{}) do
      case WorkerAPI.read_status(answer) do
        {:ok, status} -> {:ok, status}
        :error -> {:error, :lost}
      end
    end
  end

  @doc """
  The worker service's report of who used what after `after_rev`
  (`Prima.LocusPool`, the pool wire): a `POST` to its pool route signed
  with the service's pool key (`Prima.LocusPool.pool_key/2` of its worker
  key), read strictly (`Prima.LocusPool.read_answer/1`). Read only, so it
  is never retried here: the next poll asks again. `{:error,
  :unavailable}` for a service no connection was made to or no key
  derives for, `{:error, :lost}` for anything else in an answer's place.
  """
  @spec pool(WorkerAPI.endpoint(), non_neg_integer()) ::
          {:ok, Prima.LocusPool.report()} | {:error, transport_refusal()}
  def pool(%{id: id, url: url}, after_rev)
      when is_binary(id) and is_binary(url) and is_integer(after_rev) and after_rev >= 0 do
    case Keys.locus_runtime_key(id) do
      {:ok, worker_key} ->
        body = Prima.LocusPool.request_body(after_rev)
        pool_key = Prima.LocusPool.pool_key(:runtime, worker_key)

        header =
          Prima.LocusPool.header(:runtime, pool_key, System.system_time(:millisecond), body)

        pool_post(url <> Prima.LocusPool.route(), header, body)

      {:error, _invalid} ->
        {:error, :unavailable}
    end
  end

  defp pool_post(url, header, body) do
    max_bytes = HostAPI.max_answer_bytes()

    response =
      Req.request(
        method: :post,
        url: url,
        headers: [{WorkerWire.auth_header(), header}, {"content-type", "application/json"}],
        body: body,
        receive_timeout: WorkerAPI.request_timeout_ms(:status),
        connect_options: [timeout: @connect_timeout_ms],
        retry: false,
        redirect: false,
        compressed: false,
        decode_body: false,
        into: Prima.BoundedBody.collector(max_bytes)
      )

    with {:ok, %Req.Response{status: 200} = resp} <- response,
         {:ok, raw} <- Prima.BoundedBody.read(resp, max_bytes),
         {:ok, report} <- Prima.LocusPool.read_answer(raw) do
      {:ok, report}
    else
      {:error, %Req.TransportError{reason: reason}} when reason not in [:timeout, :closed] ->
        {:error, :unavailable}

      _lost ->
        {:error, :lost}
    end
  end

  # ---------------------------------------------------------------------------
  # One request
  # ---------------------------------------------------------------------------

  defp request(endpoint, callback, args) do
    case dispatch_key(endpoint.id) do
      {:ok, key} -> request(endpoint, callback, args, key, WorkerAPI.retry(callback))
      :error -> {:error, :unavailable}
    end
  end

  # A retried request is a new request under a fresh nonce; only an
  # idempotent callback's effect is repeatable.
  defp request(endpoint, callback, args, key, retry) do
    case send_request(endpoint, callback, args, key) do
      {:error, refusal} when refusal in [:lost, :unavailable] and retry == :idempotent ->
        send_request(endpoint, callback, args, key)

      answer ->
        answer
    end
  end

  defp send_request(endpoint, callback, args, key) do
    body = callback |> WorkerWire.request_body(args) |> Jason.encode!()

    request = %{
      service: endpoint.id,
      boot: Prima.Boot.id(),
      ts: System.system_time(:millisecond),
      nonce: nonce()
    }

    case WorkerAuth.request_header(key, request, body) do
      {:ok, header} ->
        post(endpoint.url <> WorkerWire.worker_route(callback), header, body, callback)

      {:error, _invalid} ->
        {:error, :unavailable}
    end
  end

  defp post(url, header, body, callback) do
    max_bytes = HostAPI.max_answer_bytes()

    response =
      Req.request(
        method: :post,
        url: url,
        headers: [{WorkerWire.auth_header(), header}, {"content-type", "application/json"}],
        body: body,
        receive_timeout: WorkerAPI.request_timeout_ms(callback),
        connect_options: [timeout: @connect_timeout_ms],
        retry: false,
        redirect: false,
        compressed: false,
        decode_body: false,
        into: Prima.BoundedBody.collector(max_bytes)
      )

    # An answer is a `200`; any other status is no answer of the worker
    # service's, whatever its body says.
    with {:ok, %Req.Response{status: 200} = resp} <- response,
         {:ok, raw} <- Prima.BoundedBody.read(resp, max_bytes) do
      answer(raw)
    else
      {:ok, %Req.Response{status: 503} = resp} when callback == :start ->
        refused_start(resp, max_bytes)

      {:ok, %Req.Response{}} ->
        {:error, :lost}

      {:error, {:response_too_large, _size, _max}} ->
        {:error, :lost}

      {:error, %Req.TransportError{reason: reason}} when reason in [:timeout, :closed] ->
        {:error, :lost}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp answer(raw) do
    case read(raw) do
      {:ok, value} -> {:ok, value}
      {:error, name, _fields} when is_map_key(@refusals, name) -> {:error, @refusals[name]}
      _unreadable -> {:error, :lost}
    end
  end

  # An answer at this wire's version, or `:lost`.
  defp read(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> WorkerWire.read_answer(decoded)
      {:error, _not_json} -> :lost
    end
  end

  # The worker service's refusal of a start, with the sentence it names,
  # or for room with what holds the memory; any other 503 is no answer of
  # the service's.
  defp refused_start(resp, max_bytes) do
    with {:ok, raw} <- Prima.BoundedBody.read(resp, max_bytes) do
      raw |> read() |> refused_start()
    else
      _ -> {:error, :lost}
    end
  end

  defp refused_start({:error, "unavailable", %{"message" => sentence}}) do
    if WorkerAPI.valid_refusal_message?(sentence),
      do: {:error, {:unavailable, sentence}},
      else: {:error, :lost}
  end

  defp refused_start({:error, "no_memory", %{"held" => wire} = fields})
       when map_size(fields) == 1 do
    case Prima.LocusPool.read_held(wire) do
      {:ok, held} -> {:error, {:no_memory, held}}
      :error -> {:error, :lost}
    end
  end

  defp refused_start(_answer), do: {:error, :lost}

  defp dispatch_key(service) do
    case Keys.locus_runtime_key(service) do
      {:ok, worker_key} -> {:ok, WorkerAuth.dispatch_key(worker_key)}
      {:error, _invalid} -> :error
    end
  end

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
end
