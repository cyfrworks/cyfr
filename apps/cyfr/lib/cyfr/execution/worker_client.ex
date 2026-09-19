# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.WorkerClient do
  @moduledoc """
  CYFR's client of one worker service (`Cyfr.WorkerAPI`) over HTTP, as
  `Cyfr.WorkerWire` frames it. `Cyfr.Execution.Dispatch` reaches every
  worker service through it, the scripted one of the test suite exactly as
  Opus.

  Each function takes the worker service's `t:Cyfr.WorkerAPI.endpoint/0`
  and answers as the `Cyfr.WorkerAPI` callback of the same name, with two
  refusals of the transport's own:

    * `{:error, :unavailable}` — the worker service could not be reached:
      no connection was made, or its configured id is not one keys derive
      over. Nothing was asked of it.
    * `{:error, :lost}` — the request went out and no readable answer came
      back within `Cyfr.WorkerAPI.request_timeout_ms/1`: the connection
      timed out or closed, or what came back is not an answer. The worker
      service may have acted.

  A request is a `POST` to the callback's route (`Cyfr.WorkerWire.worker_route/1`)
  whose body is the JSON `{"op", "args"}` and whose `x-cyfr-auth` header
  is `Cyfr.WorkerAuth.request_header/3` over that body, signed with the
  worker service's dispatch key (`Cyfr.Execution.Keys.worker_key/1`),
  naming the service the request is addressed to and this boot
  (`Cyfr.Boot.id/0`) as the incarnation presenting it, under a fresh nonce.
  An answer is a `200` read up to `Cyfr.HostAPI.max_answer_bytes/0`:
  `{"ok": value}` is the callback's success and `{"error": name}` its
  refusal; any other status, or anything else in an answer's place, is a
  lost answer. A lost answer is retried once, with a fresh nonce, when
  `Cyfr.WorkerAPI.retry/1` allows it (`kill` and `status`), never for
  `start`: its assignment's claim window bounds the worker service, and
  dispatch reconciles against the attempt.

  One listener refusal is an answer: a `start` refused `503`
  `{"error": "unavailable", "message": sentence}`, the worker service's
  account of why no runner can take it (its keeper refuses runners,
  `t:Cyfr.WorkerAPI.refusal/0`), is `{:error, {:unavailable, sentence}}`,
  since the service answers it only once it has decided to start nothing.
  A `503` without a sentence, or with one that is not a refusal's
  (`Cyfr.WorkerAPI.valid_refusal_message?/1`), stays lost: the listener
  answers it too when its call into the service timed out, after which the
  service may still start the run.
  """

  alias Cyfr.{HostAPI, WorkerAPI, WorkerAuth, WorkerWire}
  alias Cyfr.Execution.Keys

  @connect_timeout_ms 5_000

  # The refusals a worker service answers by name (`Cyfr.WorkerWire`);
  # anything else in an answer's place is a lost answer.
  @refusals %{
    "lost" => :lost,
    "unavailable" => :unavailable,
    "replayed" => :replayed,
    "malformed" => :malformed,
    "bad_mac" => :bad_mac,
    "unknown_version" => :unknown_version,
    "claim_expired" => :claim_expired,
    "not_found" => :not_found
  }

  @typedoc "What the transport itself answers when the worker service did not."
  @type transport_refusal :: :lost | :unavailable

  @doc """
  Start an assignment on `endpoint` (`c:Cyfr.WorkerAPI.start/3`): `input`
  is the execution's input bytes and `sealed_keys` the attempt's keys
  sealed for that worker service. `{:error, {:unavailable, sentence}}` is
  the worker service's refusal of the start: it started nothing, and
  `sentence` says why.
  """
  @spec start(WorkerAPI.endpoint(), Cyfr.Assignment.token(), binary(), String.t()) ::
          :ok
          | {:error, :malformed | {:unavailable, String.t()} | transport_refusal() | atom()}
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

  @doc "Stop the execution `execution_id` on `endpoint` (`c:Cyfr.WorkerAPI.kill/1`)."
  @spec kill(WorkerAPI.endpoint(), String.t()) ::
          :ok | {:error, :not_found | transport_refusal() | atom()}
  def kill(%{id: id, url: url} = endpoint, execution_id)
      when is_binary(id) and is_binary(url) and is_binary(execution_id) do
    case request(endpoint, :kill, %{"execution_id" => execution_id}) do
      {:ok, true} -> :ok
      {:ok, _other} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The state of the worker service at `endpoint` (`c:Cyfr.WorkerAPI.status/0`),
  read as `Cyfr.WorkerAPI.read_status/1` reads it: a count for every
  runner state, `tainted` included, the memory bound its runners run
  under and its keeper's refusal, and nothing else. An answer of another
  shape is lost.
  """
  @spec status(WorkerAPI.endpoint()) ::
          {:ok, WorkerAPI.status()} | {:error, transport_refusal() | atom()}
  def status(%{id: id, url: url} = endpoint) when is_binary(id) and is_binary(url) do
    with {:ok, answer} <- request(endpoint, :status, %{}) do
      case WorkerAPI.read_status(answer) do
        {:ok, status} -> {:ok, status}
        :error -> {:error, :lost}
      end
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
      boot: Cyfr.Boot.id(),
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
        into: Cyfr.BoundedBody.collector(max_bytes)
      )

    # An answer is a `200`; any other status is no answer of the worker
    # service's, whatever its body says.
    with {:ok, %Req.Response{status: 200} = resp} <- response,
         {:ok, raw} <- Cyfr.BoundedBody.read(resp, max_bytes) do
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
    case Jason.decode(raw) do
      {:ok, %{"ok" => value}} -> {:ok, value}
      {:ok, %{"error" => name}} when is_map_key(@refusals, name) -> {:error, @refusals[name]}
      _unreadable -> {:error, :lost}
    end
  end

  # The worker service's refusal of a start, with the sentence it names;
  # any other 503 is no answer of the service's.
  defp refused_start(resp, max_bytes) do
    with {:ok, raw} <- Cyfr.BoundedBody.read(resp, max_bytes),
         {:ok, %{"error" => "unavailable", "message" => sentence}} <- Jason.decode(raw),
         true <- WorkerAPI.valid_refusal_message?(sentence) do
      {:error, {:unavailable, sentence}}
    else
      _ -> {:error, :lost}
    end
  end

  defp dispatch_key(service) do
    case Keys.worker_key(service) do
      {:ok, worker_key} -> {:ok, WorkerAuth.dispatch_key(worker_key)}
      {:error, _invalid} -> :error
    end
  end

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
end
