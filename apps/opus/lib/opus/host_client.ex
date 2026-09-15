# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HostClient do
  @moduledoc """
  A runner's client of CYFR's host calls (`Cyfr.HostAPI`), for one
  execution attempt.

  A client names the attempt (its athanor, execution, attempt id, fence,
  generation and worker service), the runner presenting it and the
  attempt's keys CYFR issued with the assignment. Every call is a JSON
  body, `{"op": name, "args": {...}}`, signed with the attempt's call key
  under a fresh nonce and the current time
  (`Cyfr.WorkerAuth.host_call_header/3`), and its answer is JSON.
  `transport/2` carries the header and body to CYFR and brings the answer
  back; nothing but those strings crosses it. The attempt's seal key is
  held for the sealed transport (`Cyfr.WorkerAuth.seal_call/5`), and opens
  the keys of a child CYFR admits for this client's runner
  (`admit_child/5`).

  Each function answers as the `Cyfr.HostAPI` callback of the same name.
  An answer that cannot be read is `{:error, :lost}`.

  One call reaches CYFR beside `transport/2`: `runner_exited/3`, a worker
  service's report that one of its runners exited, signed with that worker
  service's dispatch key (`Cyfr.Execution.Host.runner_exited/2`); it
  carries only strings.
  """

  alias Cyfr.{Assignment, WorkerAuth}

  @derive {Inspect, except: [:call_key, :seal_key]}
  @enforce_keys [
    :athanor_id,
    :execution_id,
    :attempt,
    :fence,
    :generation,
    :worker,
    :runner,
    :call_key,
    :seal_key
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          execution_id: String.t(),
          attempt: String.t(),
          fence: pos_integer(),
          generation: pos_integer(),
          worker: String.t(),
          runner: String.t(),
          call_key: binary(),
          seal_key: binary()
        }

  @typedoc """
  A child CYFR admitted and claimed for this client's runner: its assignment
  token and the assignment it carries, the input it was admitted with (which
  may differ from what the guest asked for), a client for its attempt
  presenting as the same runner, and the fields its vault edge projects.
  """
  @type child :: %{
          token: Assignment.token(),
          assignment: Assignment.t(),
          input: map(),
          client: t(),
          secrets: %{optional(String.t()) => String.t()}
        }

  @attempt_fields [:athanor_id, :execution_id, :attempt, :fence, :generation]

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

  @doc """
  A client for the attempt `keys` name (`t:Cyfr.WorkerAuth.attempt_keys/0`),
  signing with its call key. `runner` names the runner presenting the
  calls; a fresh runner id is minted when it is absent.
  """
  @spec new(Cyfr.WorkerAuth.attempt_keys(), String.t() | nil) :: t()
  def new(%{attempt: attempt, call: call_key, seal: seal_key}, runner \\ nil)
      when is_map(attempt) and is_binary(call_key) and is_binary(seal_key) do
    %__MODULE__{
      athanor_id: Map.fetch!(attempt, :athanor_id),
      execution_id: Map.fetch!(attempt, :execution_id),
      attempt: Map.fetch!(attempt, :attempt),
      fence: Map.fetch!(attempt, :fence),
      generation: Map.fetch!(attempt, :generation),
      worker: Map.fetch!(attempt, :worker),
      runner: runner || Cyfr.UUID7.generate_id("runner"),
      call_key: call_key,
      seal_key: seal_key
    }
  end

  @doc "Attach with the assignment `token`, answering the run's vault fields."
  @spec attach(t(), String.t()) :: {:ok, %{optional(String.t()) => String.t()}} | {:error, term()}
  def attach(%__MODULE__{} = client, token) when is_binary(token) do
    with {:ok, %{} = secrets} <- request(client, "attach", %{"assignment" => token}),
         do: {:ok, secrets}
  end

  @doc "Renew the leases of `attempts`, answering each one's renewal by attempt id."
  @spec renew(t(), [String.t()]) ::
          {:ok, %{optional(String.t()) => Cyfr.HostAPI.renewal()}} | {:error, term()}
  def renew(%__MODULE__{} = client, attempts) when is_list(attempts) do
    with {:ok, %{} = renewals} <- request(client, "renew", %{"attempts" => attempts}) do
      {:ok, Map.new(renewals, fn {attempt, renewal} -> {attempt, renewal(renewal)} end)}
    end
  end

  @doc "Close the attempt completed with the guest's `output`, answering the output as recorded."
  @spec complete(t(), term()) :: {:ok, term()} | {:error, term()}
  def complete(%__MODULE__{} = client, output) do
    request(client, "complete", %{
      "outcome" => outcome(client, "completed", %{"output" => output})
    })
  end

  @doc """
  Close the attempt failed with the sentence `error`, answering the failure
  as recorded, masked. `abandoned: true` says the runner stopped the
  guest's component call before it returned.
  """
  @spec fail(t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def fail(%__MODULE__{} = client, error, opts \\ []) when is_binary(error) do
    fields = %{"error" => error, "abandoned" => Keyword.get(opts, :abandoned, false) == true}

    case request(client, "fail", %{"outcome" => outcome(client, "failed", fields)}) do
      {:ok, message} when is_binary(message) -> {:ok, message}
      {:ok, _other} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Deliver the guest's emitted JSON `events`, in order, answering one reply per event."
  @spec push_deltas(t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def push_deltas(%__MODULE__{} = client, events) when is_list(events) do
    deltas =
      for event <- events do
        %{
          "execution_id" => client.execution_id,
          "attempt" => client.attempt,
          "fence" => client.fence,
          "event" => event
        }
      end

    with {:ok, replies} when is_list(replies) and length(replies) == length(events) <-
           request(client, "push_deltas", %{"deltas" => deltas}) do
      if Enum.all?(replies, &is_binary/1), do: {:ok, replies}, else: {:error, :lost}
    else
      {:ok, _other} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Dispense an OAuth access token for `provider`."
  @spec oauth_token(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def oauth_token(%__MODULE__{} = client, provider) when is_binary(provider) do
    case request(client, "oauth_token", %{"provider" => provider}) do
      {:ok, token} when is_binary(token) -> {:ok, token}
      {:ok, _other} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Take one request from the consented rate for `bucket`."
  @spec take_rate(t(), String.t()) :: :ok | {:error, term()}
  def take_rate(%__MODULE__{} = client, bucket) when is_binary(bucket) do
    case request(client, "take_rate", %{"bucket" => bucket}) do
      {:ok, true} -> :ok
      {:ok, _other} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Run the guest's storage operation `op` with the guest request's `args`
  (`"path"`, and `"content"` for a write or append), answering the
  success answer's members.
  """
  @spec storage(t(), Cyfr.HostAPI.storage_op(), map()) :: {:ok, map()} | {:error, term()}
  def storage(%__MODULE__{} = client, op, args)
      when op in [:read, :write, :append, :list, :delete, :exists] and is_map(args) do
    case request(client, "storage", Map.put(args, "action", Atom.to_string(op))) do
      {:ok, %{} = members} -> {:ok, members}
      {:ok, _other} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The bytes of the attempt's component artifact with `digest`."
  @spec fetch_artifact(t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch_artifact(%__MODULE__{} = client, digest) when is_binary(digest) do
    with {:ok, encoded} when is_binary(encoded) <-
           request(client, "fetch_artifact", %{"digest" => digest}),
         {:ok, bytes} <- Base.decode64(encoded) do
      {:ok, bytes}
    else
      {:error, reason} -> {:error, reason}
      _unreadable -> {:error, :lost}
    end
  end

  @doc """
  Record a refusal of the runner's own egress checks for the attempt's
  component: its WIT error `type` and `message`.
  """
  @spec record_denial(t(), String.t(), String.t()) :: :ok | {:error, term()}
  def record_denial(%__MODULE__{} = client, type, message)
      when is_binary(type) and is_binary(message) do
    case request(client, "record_denial", %{"type" => type, "message" => message}) do
      {:ok, true} -> :ok
      {:ok, _other} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Admit a child the attempt's guest starts on `reference`, through the edge
  named `need`, with `input`, made with `guest_fn` (`:call` or `:spawn`).
  CYFR admits it under the authority it holds for this attempt and claims
  it for this client's runner. Answers the child to run (`t:child/0`),
  once its keys open under this attempt's seal key as the attempt its
  assignment names on this client's worker service, and its input hashes
  to the assignment's digest. A refusal of the child is
  `{:error, guest_error}` (`t:Cyfr.HostAPI.guest_error/0`).
  """
  @spec admit_child(t(), String.t(), term(), map(), :call | :spawn) ::
          {:ok, child()} | {:error, term()}
  def admit_child(%__MODULE__{} = client, reference, need, input, guest_fn)
      when is_binary(reference) and is_map(input) and guest_fn in [:call, :spawn] do
    args = %{
      "reference" => reference,
      "need" => need,
      "input" => input,
      "guest_fn" => Atom.to_string(guest_fn)
    }

    with {:ok,
          %{
            "assignment" => token,
            "attempt_keys" => sealed,
            "input" => input_json,
            "secrets" => %{} = secrets
          }}
         when is_binary(input_json) <- request(client, "admit_child", args),
         {:ok, keys} <- WorkerAuth.open_attempt_keys(client.seal_key, sealed),
         {:ok, assignment} <- Assignment.read(token),
         true <- names_attempt?(assignment, keys.attempt, client.worker),
         true <- Cyfr.Digest.sha256(input_json) == assignment.input_digest,
         {:ok, %{} = admitted_input} <- Jason.decode(input_json) do
      {:ok,
       %{
         token: token,
         assignment: assignment,
         input: admitted_input,
         client: new(keys, client.runner),
         secrets: secrets
       }}
    else
      {:error, {:guest_error, _type, _message} = refusal} -> {:error, refusal}
      {:error, {:guest_error, _type, _message, _remediation} = refusal} -> {:error, refusal}
      {:error, :unavailable} -> {:error, :unavailable}
      _unreadable -> {:error, :lost}
    end
  end

  @doc """
  Run the catalog tool `name` with `args` for the attempt's guest, which
  made it with `guest_fn` (`:call` or `:spawn`). Answers the tool's result,
  or a refusal the guest is handed as `{:error, guest_error}`.
  """
  @spec tool_call(t(), String.t(), map(), :call | :spawn) :: {:ok, term()} | {:error, term()}
  def tool_call(%__MODULE__{} = client, name, args, guest_fn)
      when is_binary(name) and is_map(args) and guest_fn in [:call, :spawn] do
    request(client, "tool_call", %{
      "name" => name,
      "args" => args,
      "guest_fn" => Atom.to_string(guest_fn)
    })
  end

  @doc """
  Report, for the worker service `worker` holding its `dispatch_key`, that
  one of its runners exited while it held `attempts`. Answers `:ok`, or
  `{:error, :lost | :unavailable}`.
  """
  @spec runner_exited(binary(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def runner_exited(dispatch_key, worker, attempts)
      when is_binary(dispatch_key) and is_binary(worker) and is_list(attempts) do
    body = Jason.encode!(%{"op" => "runner_exited", "args" => %{"attempts" => attempts}})
    report = %{worker: worker, ts: System.system_time(:millisecond), nonce: nonce()}

    with {:ok, header} <- WorkerAuth.report_header(dispatch_key, report, body),
         {:ok, true} <- header |> Cyfr.Execution.Host.runner_exited(body) |> answer() do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :lost}
    end
  end

  @doc """
  Carry one signed host call to CYFR: the header and the JSON body it
  signs, answered with CYFR's JSON.
  """
  @spec transport(String.t(), String.t()) :: String.t()
  def transport(header, body) when is_binary(header) and is_binary(body),
    do: Cyfr.Execution.Host.call(header, body)

  defp request(client, op, args) do
    with {:ok, body} <- Jason.encode(%{"op" => op, "args" => args}),
         {:ok, header} <- WorkerAuth.host_call_header(client.call_key, call_fields(client), body) do
      header |> transport(body) |> answer()
    else
      _ -> {:error, :lost}
    end
  end

  defp call_fields(client) do
    %{
      athanor_id: client.athanor_id,
      execution_id: client.execution_id,
      attempt: client.attempt,
      fence: client.fence,
      generation: client.generation,
      worker: client.worker,
      runner: client.runner,
      ts: System.system_time(:millisecond),
      nonce: nonce()
    }
  end

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  # A child's assignment must name the attempt its keys open as, on this
  # client's worker service.
  defp names_attempt?(%Assignment{} = assignment, attempt, worker) do
    Map.take(assignment, @attempt_fields) == Map.take(attempt, @attempt_fields) and
      assignment.audience == worker and attempt.worker == worker
  end

  defp outcome(client, status, fields) do
    Map.merge(fields, %{
      "execution_id" => client.execution_id,
      "attempt" => client.attempt,
      "fence" => client.fence,
      "status" => status
    })
  end

  defp answer(json) do
    case Jason.decode(json) do
      {:ok, %{"ok" => value}} ->
        {:ok, value}

      {:ok, %{"error" => "setup_required", "payload" => %{} = payload}} ->
        {:error, {:setup_required, payload}}

      {:ok, %{"error" => "guest_error", "type" => type, "message" => message} = refusal}
      when is_binary(type) and is_binary(message) ->
        guest_error(refusal, type, message)

      {:ok, %{"error" => "failed", "message" => message}} when is_binary(message) ->
        {:error, {:failed, message}}

      {:ok, %{"error" => refusal}} when is_map_key(@refusals, refusal) ->
        {:error, Map.fetch!(@refusals, refusal)}

      _ ->
        {:error, :lost}
    end
  end

  defp guest_error(%{"remediation" => %{} = remediation}, type, message),
    do: {:error, {:guest_error, type, message, remediation}}

  defp guest_error(_refusal, type, message), do: {:error, {:guest_error, type, message}}

  defp renewal(%{"lease_until" => until}) when is_integer(until), do: {:ok, until}
  defp renewal("cancel"), do: :cancel
  defp renewal(_lost), do: :lost
end
