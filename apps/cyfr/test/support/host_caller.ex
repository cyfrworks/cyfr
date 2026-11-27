# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.HostCaller do
  @moduledoc """
  One host call of an attempt, posted to CYFR's host API as a runner's
  worker service posts it, and nothing else: no retry, no redirect, no
  reading of the answer beyond what the wire says.

  A call is the versioned JSON body of `op` and `args`
  (`Prima.WorkerWire.request_body/2`), sealed to fresh call fields with
  the attempt's seal key (`Prima.WorkerAuth.seal_call/5`) and signed with
  its call key (`Prima.WorkerAuth.host_call_header/3`), posted once to the
  callback's route (`Prima.WorkerWire.host_route/1`) with
  `Prima.HostAPI.request_timeout_ms/1` as its timeout. Its answer is one of:

  - `{:ok, value}` — CYFR's answer of `value`;
  - `{:error, name, fields}` — CYFR's refusal `name` and its other fields
    (`Prima.WorkerWire.read_answer/1`);
  - `{:refused, status, body}` — the listener's refusal by any status but
    `200`, with its body;
  - `:lost` — no answer: the transport failed, the timeout passed, or the
    `200` answer does not open under the call's fields or is no answer at
    this wire's version.

  Calling it twice with the same `args` posts the same body twice under
  fresh headers, as a retried call is posted: an `admit_child` sent twice
  carries the same `child_key`.

  An attempt is a map naming its `athanor_id`, `execution_id`, `attempt`,
  `fence`, `generation` and `service`, the `boot`, `runner` and `member`
  its calls present, and its `keys` (`t:Prima.WorkerAuth.attempt_keys/0`):
  `Cyfr.Test.AttemptFixtures.attached!/1` answers one, and `child/2` one
  for a child CYFR admitted. It names no runtime module, so it serves the
  core's tests whichever runner the runtime runs.
  """

  alias Prima.{Assignment, HostAPI, WorkerAuth, WorkerWire}

  @type answer ::
          {:ok, term()}
          | {:error, String.t(), map()}
          | {:refused, pos_integer(), binary()}
          | :lost

  @doc "Post the host call `op` with `args` for `attempt` to the host API at `url`, once."
  @spec call(map(), String.t(), atom(), map()) :: answer()
  def call(attempt, url, op, args)
      when is_binary(url) and is_atom(op) and is_map(args) do
    %{call: call_key, seal: seal_key} = attempt.keys
    fields = fields(attempt)
    json = Jason.encode!(WorkerWire.request_body(op, args))
    {:ok, sealed} = WorkerAuth.seal_call(seal_key, :body, fields, json)
    {:ok, header} = WorkerAuth.host_call_header(call_key, fields, sealed)

    request = [
      method: :post,
      url: url <> WorkerWire.host_route(op),
      headers: [{WorkerWire.auth_header(), header}, {"content-type", "application/json"}],
      body: sealed,
      receive_timeout: HostAPI.request_timeout_ms(op),
      connect_options: [timeout: HostAPI.request_timeout_ms(op)],
      retry: false,
      redirect: false,
      compressed: false,
      decode_body: false
    ]

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: raw}} -> opened(seal_key, fields, raw)
      {:ok, %Req.Response{status: status, body: raw}} -> {:refused, status, raw}
      {:error, _transport} -> :lost
    end
  end

  @doc """
  The attempt of a child CYFR admitted for `parent` (the value of its
  `admit_child` answer): its keys opened under the parent's seal key, the
  `assignment` read from its token and the `input` it was admitted with,
  presented by the parent's runner, boot and member, as the runner the
  child was handed to presents it.
  """
  @spec child(map(), map()) :: map()
  def child(parent, %{"assignment" => token, "attempt_keys" => sealed, "input" => input}) do
    {:ok, keys} = WorkerAuth.open_attempt_keys(parent.keys.seal, sealed)
    {:ok, assignment} = Assignment.read(token)

    Map.merge(keys.attempt, %{
      keys: keys,
      call_key: keys.call,
      boot: parent.boot,
      runner: parent.runner,
      member: parent.member,
      assignment: assignment,
      input: Jason.decode!(input)
    })
  end

  defp fields(attempt) do
    attempt
    |> Map.take([
      :athanor_id,
      :execution_id,
      :attempt,
      :fence,
      :generation,
      :service,
      :boot,
      :runner,
      :member
    ])
    |> Map.merge(%{
      ts: System.system_time(:millisecond),
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    })
  end

  defp opened(seal_key, fields, raw) do
    with {:ok, json} <- WorkerAuth.open_call(seal_key, :answer, fields, raw),
         {:ok, decoded} <- Jason.decode(json) do
      WorkerWire.read_answer(decoded)
    else
      _unreadable -> :lost
    end
  end
end
