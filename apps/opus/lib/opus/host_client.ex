# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HostClient do
  @moduledoc """
  A runner's client of CYFR's host calls (`Cyfr.HostAPI`), for one
  execution attempt, over HTTP.

  A client names the attempt (its athanor, execution, attempt id, fence,
  generation and worker service), the runner presenting it, the attempt's
  keys CYFR issued with the assignment and the base URL of CYFR's host
  API. Every call is one `POST` to the callback's route
  (`Cyfr.WorkerWire.host_route/1`): its body is the JSON
  `{"op": name, "args": {...}}` sealed with the attempt's seal key to the
  call's fields (`Cyfr.WorkerAuth.seal_call/5`), and its `x-cyfr-auth`
  header is the attempt's call-key signature over those fields — a fresh
  nonce and the current time among them — and the sealed body
  (`Cyfr.WorkerAuth.host_call_header/3`). A `200` answer is the JSON
  `Cyfr.WorkerWire` describes, sealed to the same fields in the answer
  direction and read up to `Cyfr.HostAPI.max_answer_bytes/0`; any other
  status is the listener's refusal, and is lost. The attempt's seal key
  also opens the keys of a child CYFR admits for this client's runner
  (`admit_child/5`).

  Each function answers as the `Cyfr.HostAPI` callback of the same name.
  An answer that does not arrive within `Cyfr.HostAPI.request_timeout_ms/1`,
  or cannot be read, is lost, and what the client does then is the
  callback's retry class (`Cyfr.HostAPI.retry/1`): an `:idempotent`,
  `:outcome`, `:batch` or `:keyed` call is made once more — the same body
  under a fresh header, so a `push_deltas` batch goes again as the same
  batch and an `admit_child` under the same `child_key` — and a `:never`
  call ends `{:error, {:uncertain, sentence}}`, since its effect may have
  happened. A second loss is `{:error, :lost}`. CYFR's own answers, `lost`
  included, are never retried: they are answers.

  One call reaches CYFR beside a runner's: `runner_exited/4`, a worker
  service's report that one of its runners exited, a plain JSON body
  signed with that worker service's dispatch key and posted to the
  `runner_exited` host route, answered in plain JSON.

  Nothing a call carries is logged: the keys are kept out of a client's
  inspection, and a loss is logged by its operation and reason alone.
  """

  require Logger

  alias Cyfr.{Assignment, BoundedBody, HostAPI, WorkerAuth, WorkerWire}

  @derive {Inspect, except: [:call_key, :seal_key]}
  @enforce_keys [
    :athanor_id,
    :execution_id,
    :attempt,
    :fence,
    :generation,
    :service,
    :boot,
    :runner,
    :call_key,
    :seal_key,
    :host_url
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          execution_id: String.t(),
          attempt: String.t(),
          fence: pos_integer(),
          generation: pos_integer(),
          service: String.t(),
          boot: String.t(),
          runner: String.t(),
          call_key: binary(),
          seal_key: binary(),
          host_url: String.t()
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

  @uncertain "The call's answer was lost and its effect is unknown"

  @doc """
  A client for the attempt `keys` name (`t:Cyfr.WorkerAuth.attempt_keys/0`),
  signing with its call key and posting to the host API at `host_url`.
  `runner` names the runner presenting the calls (a fresh runner id is
  minted when it is nil) and `boot` the worker service boot it presents
  from.
  """
  @spec new(Cyfr.WorkerAuth.attempt_keys(), String.t() | nil, String.t(), String.t()) :: t()
  def new(%{attempt: attempt, call: call_key, seal: seal_key}, runner, boot, host_url)
      when is_map(attempt) and is_binary(call_key) and is_binary(seal_key) and is_binary(boot) and
             is_binary(host_url) do
    %__MODULE__{
      athanor_id: Map.fetch!(attempt, :athanor_id),
      execution_id: Map.fetch!(attempt, :execution_id),
      attempt: Map.fetch!(attempt, :attempt),
      fence: Map.fetch!(attempt, :fence),
      generation: Map.fetch!(attempt, :generation),
      service: Map.fetch!(attempt, :service),
      boot: boot,
      runner: runner || Cyfr.UUID7.generate_id("runner"),
      call_key: call_key,
      seal_key: seal_key,
      host_url: host_url
    }
  end

  @doc "Attach with the assignment `token`, answering the run's vault fields."
  @spec attach(t(), String.t()) :: {:ok, %{optional(String.t()) => String.t()}} | {:error, term()}
  def attach(%__MODULE__{} = client, token) when is_binary(token) do
    with {:ok, %{} = secrets} <- request(client, :attach, %{"assignment" => token}),
         do: {:ok, secrets}
  end

  @doc "Renew the leases of `attempts`, answering each one's renewal by attempt id."
  @spec renew(t(), [String.t()]) ::
          {:ok, %{optional(String.t()) => Cyfr.HostAPI.renewal()}} | {:error, term()}
  def renew(%__MODULE__{} = client, attempts) when is_list(attempts) do
    with {:ok, %{} = renewals} <- request(client, :renew, %{"attempts" => attempts}) do
      {:ok, Map.new(renewals, fn {attempt, renewal} -> {attempt, renewal(renewal)} end)}
    end
  end

  @doc "Close the attempt completed with the guest's `output`, answering the output as recorded."
  @spec complete(t(), term()) :: {:ok, term()} | {:error, term()}
  def complete(%__MODULE__{} = client, output) do
    request(client, :complete, %{
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

    case request(client, :fail, %{"outcome" => outcome(client, "failed", fields)}) do
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
           request(client, :push_deltas, %{"deltas" => deltas}) do
      if Enum.all?(replies, &is_binary/1), do: {:ok, replies}, else: {:error, :lost}
    else
      {:ok, _other} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Dispense an OAuth access token for `provider`."
  @spec oauth_token(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def oauth_token(%__MODULE__{} = client, provider) when is_binary(provider) do
    case request(client, :oauth_token, %{"provider" => provider}) do
      {:ok, token} when is_binary(token) -> {:ok, token}
      {:ok, _other} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Take one request from the consented rate for `bucket`."
  @spec take_rate(t(), String.t()) :: :ok | {:error, term()}
  def take_rate(%__MODULE__{} = client, bucket) when is_binary(bucket) do
    case request(client, :take_rate, %{"bucket" => bucket}) do
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
    case request(client, :storage, Map.put(args, "action", Atom.to_string(op))) do
      {:ok, %{} = members} -> {:ok, members}
      {:ok, _other} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The bytes of the attempt's component artifact with `digest`."
  @spec fetch_artifact(t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch_artifact(%__MODULE__{} = client, digest) when is_binary(digest) do
    with {:ok, encoded} when is_binary(encoded) <-
           request(client, :fetch_artifact, %{"digest" => digest}),
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
    case request(client, :record_denial, %{"type" => type, "message" => message}) do
      {:ok, true} -> :ok
      {:ok, _other} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Admit a child the attempt's guest starts on `reference`, through the edge
  named `need`, with `input`, made with `guest_fn` (`:call` or `:spawn`).
  CYFR admits it under the authority it holds for this attempt and claims
  it for this client's runner, under a `child_key` this client mints
  (`t:Cyfr.HostAPI.child_key/0`), so a lost answer is asked again for the
  same child. Answers the child to run (`t:child/0`), once its keys open
  under this attempt's seal key as the attempt its assignment names on
  this client's worker service, and its input hashes to the assignment's
  digest. A refusal of the child is `{:error, guest_error}`
  (`t:Cyfr.HostAPI.guest_error/0`).
  """
  @spec admit_child(t(), String.t(), term(), map(), :call | :spawn) ::
          {:ok, child()} | {:error, term()}
  def admit_child(%__MODULE__{} = client, reference, need, input, guest_fn)
      when is_binary(reference) and is_map(input) and guest_fn in [:call, :spawn] do
    args = %{
      "reference" => reference,
      "need" => need,
      "input" => input,
      "guest_fn" => Atom.to_string(guest_fn),
      "child_key" => nonce()
    }

    with {:ok,
          %{
            "assignment" => token,
            "attempt_keys" => sealed,
            "input" => input_json,
            "secrets" => %{} = secrets
          }}
         when is_binary(input_json) <- request(client, :admit_child, args),
         {:ok, assignment} <- Assignment.read(token) do
      with {:ok, keys} <- WorkerAuth.open_attempt_keys(client.seal_key, sealed),
           true <- names_attempt?(assignment, keys.attempt, client),
           true <- Cyfr.Digest.sha256(input_json) == assignment.input_digest,
           {:ok, %{} = admitted_input} <- Jason.decode(input_json) do
        {:ok,
         %{
           token: token,
           assignment: assignment,
           input: admitted_input,
           client: new(keys, client.runner, client.boot, client.host_url),
           secrets: secrets
         }}
      else
        # Admitted for this runner but not startable by it: give it back at
        # once rather than leaving it to its lease.
        _unopenable ->
          _ = release_child(client, assignment.execution_id)
          {:error, :lost}
      end
    else
      {:error, {:guest_error, _type, _message} = refusal} -> {:error, refusal}
      {:error, {:guest_error, _type, _message, _remediation} = refusal} -> {:error, refusal}
      {:error, :unavailable} -> {:error, :unavailable}
      _unreadable -> {:error, :lost}
    end
  end

  @doc """
  Give back the child `execution_id` this client's runner was handed but
  could not start, so CYFR closes it failed and releases what it held.
  Answers `:ok`, or `{:error, :lost | :unavailable}`.
  """
  @spec release_child(t(), String.t()) :: :ok | {:error, term()}
  def release_child(%__MODULE__{} = client, execution_id) when is_binary(execution_id) do
    case request(client, :release_child, %{"execution_id" => execution_id}) do
      {:ok, true} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :lost}
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
    request(client, :tool_call, %{
      "name" => name,
      "args" => args,
      "guest_fn" => Atom.to_string(guest_fn)
    })
  end

  @doc """
  Report, for the worker service `credentials` name on its boot `boot`,
  that its runner `runner` exited while it held `attempts`. The report is
  signed with the service's dispatch key and posted to the host API the
  credentials name. Answers `:ok`, or `{:error, :lost | :unavailable}`.
  """
  @spec runner_exited(Opus.Credentials.t(), String.t(), String.t(), [String.t()]) ::
          :ok | {:error, term()}
  def runner_exited(%Opus.Credentials{} = credentials, boot, runner, attempts)
      when is_binary(boot) and is_binary(runner) and is_list(attempts) do
    body =
      Jason.encode!(
        WorkerWire.request_body(:runner_exited, %{"runner" => runner, "attempts" => attempts})
      )

    try = fn ->
      report = %{
        service: credentials.service_id,
        boot: boot,
        ts: System.system_time(:millisecond),
        nonce: nonce()
      }

      with {:ok, header} <- WorkerAuth.report_header(credentials.dispatch_key, report, body),
           do: {:ok, header, body, &{:ok, &1}}
    end

    case call(credentials.host_url, :runner_exited, try) do
      {:ok, true} -> :ok
      {:ok, _other} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  # Each try seals the body to fresh call fields and signs them, and opens
  # the answer as the same call.
  defp request(client, op, args) do
    json = Jason.encode!(WorkerWire.request_body(op, args))

    try = fn ->
      fields = call_fields(client)

      with {:ok, sealed} <- WorkerAuth.seal_call(client.seal_key, :body, fields, json),
           {:ok, header} <- WorkerAuth.host_call_header(client.call_key, fields, sealed) do
        {:ok, header, sealed, &WorkerAuth.open_call(client.seal_key, :answer, fields, &1)}
      end
    end

    call(client.host_url, op, try)
  end

  # One call: sealed and signed afresh for each try (`try` answers the
  # header, the body and how to read the answer), retried once after a
  # lost answer when its class allows, never on an answer CYFR gave.
  defp call(host_url, op, try) do
    answer =
      case post(host_url, op, try) do
        {:ok, answer} ->
          answer

        :lost ->
          case HostAPI.retry(op) do
            :never ->
              Logger.warning("[Opus.HostClient] #{op}'s answer was lost; its effect is uncertain")
              {:error, {:uncertain, @uncertain}}

            _retried ->
              Logger.warning("[Opus.HostClient] #{op}'s answer was lost; calling once more")

              case post(host_url, op, try) do
                {:ok, answer} -> answer
                :lost -> {:error, :lost}
              end
          end
      end

    # A lost answer, whether CYFR's `lost` or one that never arrived,
    # leaves what the call did unknown: the subtree's runner is never
    # reused (`Opus.Subtree.unclean/1`).
    case answer do
      {:error, :lost} -> Opus.Subtree.unclean({op, :lost})
      {:error, {:uncertain, _}} -> Opus.Subtree.unclean({op, :uncertain})
      _ -> :ok
    end

    answer
  end

  defp post(host_url, op, try) do
    with {:ok, header, body, read} <- try.(),
         {:ok, raw} <- transport(host_url <> WorkerWire.host_route(op), header, body, op),
         {:ok, json} <- read.(raw) do
      answer(json)
    else
      _ -> :lost
    end
  end

  # The bytes of a `200` answer, or `:error` for anything else: a refusal
  # by status, a transport failure, an answer past the bound or later than
  # the callback's timeout. No answer body is logged.
  defp transport(url, header, body, op) do
    max = HostAPI.max_answer_bytes()

    request = [
      method: :post,
      url: url,
      headers: [{WorkerWire.auth_header(), header}, {"content-type", "application/json"}],
      body: body,
      receive_timeout: HostAPI.request_timeout_ms(op),
      connect_options: [timeout: HostAPI.request_timeout_ms(op)],
      retry: false,
      redirect: false,
      compressed: false,
      decode_body: false,
      into: BoundedBody.collector(max)
    ]

    with {:ok, %Req.Response{status: 200} = response} <- Req.request(request),
         {:ok, raw} <- BoundedBody.read(response, max) do
      {:ok, raw}
    else
      _ -> :error
    end
  end

  defp call_fields(client) do
    %{
      athanor_id: client.athanor_id,
      execution_id: client.execution_id,
      attempt: client.attempt,
      fence: client.fence,
      generation: client.generation,
      service: client.service,
      boot: client.boot,
      runner: client.runner,
      ts: System.system_time(:millisecond),
      nonce: nonce()
    }
  end

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  # A child's assignment must name the attempt its keys open as, on this
  # client's worker service and boot.
  defp names_attempt?(%Assignment{} = assignment, attempt, %__MODULE__{} = client) do
    Map.take(assignment, @attempt_fields) == Map.take(attempt, @attempt_fields) and
      assignment.service == client.service and assignment.boot == client.boot and
      attempt.service == client.service
  end

  defp outcome(client, status, fields) do
    Map.merge(fields, %{
      "execution_id" => client.execution_id,
      "attempt" => client.attempt,
      "fence" => client.fence,
      "status" => status
    })
  end

  # An answer CYFR gave, or `:lost` for bytes that are not one.
  defp answer(json) do
    case Jason.decode(json) do
      {:ok, %{"ok" => value}} ->
        {:ok, {:ok, value}}

      {:ok, %{"error" => "setup_required", "payload" => %{} = payload}} ->
        {:ok, {:error, {:setup_required, payload}}}

      {:ok, %{"error" => "guest_error", "type" => type, "message" => message} = refusal}
      when is_binary(type) and is_binary(message) ->
        {:ok, guest_error(refusal, type, message)}

      {:ok, %{"error" => "failed", "message" => message}} when is_binary(message) ->
        {:ok, {:error, {:failed, message}}}

      {:ok, %{"error" => refusal}} when is_map_key(@refusals, refusal) ->
        {:ok, {:error, Map.fetch!(@refusals, refusal)}}

      _ ->
        :lost
    end
  end

  defp guest_error(%{"remediation" => %{} = remediation}, type, message),
    do: {:error, {:guest_error, type, message, remediation}}

  defp guest_error(_refusal, type, message), do: {:error, {:guest_error, type, message}}

  defp renewal(%{"lease_until" => until}) when is_integer(until), do: {:ok, until}
  defp renewal(_lost), do: :lost
end
