# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HostClient do
  @moduledoc """
  A client of CYFR's host calls (`Prima.HostAPI`) for one execution
  attempt, and the worker service's poster of every host call.

  A runner has no network. Its client sends each call through its relay
  (`Opus.Relay.Runner`, the `:relay` a client is made with), whose service
  end (`Opus.Relay`) verifies the call under the attempt's keys and posts
  it unchanged with `post_call/4`: every host call reaches CYFR from the
  worker service, never from a runner. The service's own calls for an
  attempt (the `take_rate` its relay takes before a fetch) are made by a
  client posting directly (`:host_url`), as are its runner exit reports.

  A client names the attempt (its athanor, execution, attempt id, fence,
  generation and worker service), the runner presenting it, the attempt's
  keys CYFR issued with the assignment, and **the member that issued that
  assignment**: its boot id and the base URL of its host API, both read
  from the assignment (`Prima.Assignment`). An attempt has one process, on
  that member, so its calls are posted at that member's address and name
  it in every header; a member that is not the one named refuses them,
  and an assignment naming no address is posted to the address this
  worker service is configured with (`Opus.Credentials`), which is the
  whole deployment where only one member issues. Every call is one `POST`
  to the callback's route
  (`Prima.WorkerWire.host_route/1`): its body is the versioned JSON
  `{"v": 1, "op": name, "args": {...}}` (`Prima.WorkerWire.request_body/2`)
  sealed with the attempt's seal key to the call's fields
  (`Prima.WorkerAuth.seal_call/5`), and its `x-cyfr-auth` header is the
  attempt's call-key signature over those fields — a fresh nonce and the
  current time among them — and the sealed body
  (`Prima.WorkerAuth.host_call_header/3`). A `200` answer is the JSON
  `Prima.WorkerWire` describes, sealed to the same fields in the answer
  direction, read up to `Prima.HostAPI.max_answer_bytes/0` and read as an
  answer of this wire's version (`Prima.WorkerWire.read_answer/1`); an
  answer without `v`, or at another version, is no answer and is lost.
  Any other status is the listener's refusal, and is lost, except a
  refusal naming `unknown_version`: the host speaks another version of the
  wire, so it is not this engine's host, and the call is answered
  `{:error, :lost}` at once, which stops the attempt's work, rather than
  asked again. The attempt's seal key also opens the keys of a child CYFR
  admits for this client's runner (`admit_child/5`), whose attempt the
  runner's relay then carries.

  Each function answers as the `Prima.HostAPI` callback of the same name.
  An answer that does not arrive within `Prima.HostAPI.request_timeout_ms/1`,
  or cannot be read, is lost, and what the client does then is the
  callback's retry class (`Prima.HostAPI.retry/1`): an `:idempotent`,
  `:outcome`, `:batch` or `:keyed` call is made once more — the same body
  under a fresh header, so a `push_deltas` batch goes again as the same
  batch and an `admit_child` under the same `child_key` — and a `:never`
  call ends `{:error, {:uncertain, sentence}}`, since its effect may have
  happened. A second loss is `{:error, :lost}`. CYFR's own answers, `lost`
  included, are never retried: they are answers.

  `egress_pin/3` asks CYFR for the address a guest's outbound URL may be
  reached at (`c:Prima.HostAPI.egress_pin/3`): the engine resolves no name
  itself, and connects to the address the answer names
  (`Opus.Egress.pin/3`).

  `attached_fetch/3` posts a guest's request naming a connection, which
  CYFR makes itself with the credential attached, and hands the answer's
  sealed frames to its caller as they arrive, unopened: the worker
  service's relay posts it for its runner (`Opus.Relay`), and only the
  runner opens the frames. Every other call is read whole.

  One call reaches CYFR beside a runner's: `runner_exited/4`, a worker
  service's report that one of its runners exited, a plain JSON body
  signed with that worker service's dispatch key and posted to the
  `runner_exited` host route, answered in plain JSON.

  Nothing a call carries is logged: the keys are kept out of a client's
  inspection, and a loss is logged by its operation and reason alone.
  """

  require Logger

  alias Prima.{
    Assignment,
    AttachedRequest,
    BoundedBody,
    HostAPI,
    PinnedTarget,
    WorkerAuth,
    WorkerWire
  }

  @derive {Inspect, except: [:call_key, :seal_key]}
  # A client posts through a runner's relay (`relay`) or directly to the
  # member's address (`host_url`), never both.
  @enforce_keys [
    :athanor_id,
    :execution_id,
    :attempt,
    :fence,
    :generation,
    :service,
    :boot,
    :runner,
    :member,
    :call_key,
    :seal_key,
    :host_url
  ]
  defstruct @enforce_keys ++ [relay: nil]

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          execution_id: String.t(),
          attempt: String.t(),
          fence: pos_integer(),
          generation: pos_integer(),
          service: String.t(),
          boot: String.t(),
          runner: String.t(),
          member: String.t(),
          call_key: binary(),
          seal_key: binary(),
          host_url: String.t() | nil,
          relay: GenServer.server() | nil
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
    "claim_expired" => :claim_expired,
    "not_found" => :not_found
  }

  # The refusals only an `egress_pin` answer names.
  @pin_refusals Map.new(PinnedTarget.refusals(), &{Atom.to_string(&1), &1})

  @uncertain "The call's answer was lost and its effect is unknown"

  @doc """
  A client for the attempt `keys` name (`t:Prima.WorkerAuth.attempt_keys/0`),
  signing with its call key, addressed to the member `at` names: its
  `member` boot id, which every header presents, and either the `relay`
  a runner sends its calls through (`Opus.Relay.Runner`) or the
  `host_url` the worker service posts to. `runner` names the runner
  presenting the calls (a fresh runner id is minted when it is nil) and
  `boot` the worker service boot it presents from.
  """
  @spec new(
          Prima.WorkerAuth.attempt_keys(),
          String.t() | nil,
          String.t(),
          %{member: String.t(), host_url: String.t()}
          | %{member: String.t(), relay: GenServer.server()}
        ) :: t()
  def new(keys, runner, boot, %{member: member, relay: relay}) when relay != nil,
    do: build(keys, runner, boot, member, {nil, relay})

  def new(keys, runner, boot, %{member: member, host_url: host_url}) when is_binary(host_url),
    do: build(keys, runner, boot, member, {host_url, nil})

  defp build(
         %{attempt: attempt, call: call_key, seal: seal_key},
         runner,
         boot,
         member,
         {url, relay}
       )
       when is_map(attempt) and is_binary(call_key) and is_binary(seal_key) and is_binary(boot) and
              is_binary(member) do
    %__MODULE__{
      athanor_id: Map.fetch!(attempt, :athanor_id),
      execution_id: Map.fetch!(attempt, :execution_id),
      attempt: Map.fetch!(attempt, :attempt),
      fence: Map.fetch!(attempt, :fence),
      generation: Map.fetch!(attempt, :generation),
      service: Map.fetch!(attempt, :service),
      boot: boot,
      runner: runner || Prima.UUID7.generate_id("runner"),
      member: member,
      call_key: call_key,
      seal_key: seal_key,
      host_url: url,
      relay: relay
    }
  end

  @doc """
  Where an attempt's host calls go: the member `assignment` was issued by
  and the address that member is reached at, which is the assignment's own
  unless it names none, and then `fallback` — the address this worker
  service was configured with.
  """
  @spec at(Assignment.t(), String.t()) :: %{member: String.t(), host_url: String.t()}
  def at(%Assignment{} = assignment, fallback) when is_binary(fallback),
    do: %{member: assignment.member, host_url: assignment.host_url || fallback}

  @doc "Attach with the assignment `token`, answering the run's vault fields."
  @spec attach(t(), String.t()) :: {:ok, %{optional(String.t()) => String.t()}} | {:error, term()}
  def attach(%__MODULE__{} = client, token) when is_binary(token) do
    with {:ok, %{} = secrets} <- request(client, :attach, %{"assignment" => token}),
         do: {:ok, secrets}
  end

  @doc "Renew the leases of `attempts`, answering each one's renewal by attempt id."
  @spec renew(t(), [String.t()]) ::
          {:ok, %{optional(String.t()) => Prima.HostAPI.renewal()}} | {:error, term()}
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
  @spec storage(t(), Prima.HostAPI.storage_op(), map()) :: {:ok, map()} | {:error, term()}
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
  Record a refusal the runner made for the attempt's component: one of its
  own egress checks, by its WIT error `type` and `message`, or
  `secret_denied` with the vault field name the guest was refused
  (`Prima.HostAPI.valid_field_name?/1`), which CYFR audits for this attempt.
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
  (`t:Prima.HostAPI.child_key/0`), so a lost answer is asked again for the
  same child. Answers the child to run (`t:child/0`), once its keys open
  under this attempt's seal key as the attempt its assignment names on
  this client's worker service, and its input hashes to the assignment's
  digest. A refusal of the child is `{:error, guest_error}`
  (`t:Prima.HostAPI.guest_error/0`).
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
           true <- Prima.Digest.sha256(input_json) == assignment.input_digest,
           {:ok, %{} = admitted_input} <- Jason.decode(input_json),
           :ok <- carried(client, assignment.attempt) do
        {:ok,
         %{
           token: token,
           assignment: assignment,
           input: admitted_input,
           client: new(keys, client.runner, client.boot, at(client)),
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
  Pin the address the attempt's guest may reach `url` at, for one request
  of the `:purpose` `opts` names (`:fetch`, `:stream` or `:redirect`,
  default `:fetch`), naming for a redirect the id of the pin the
  redirecting answer came from (`:from`). Answers the pin CYFR validated
  (`Prima.PinnedTarget`), a refusal it names
  (`Prima.PinnedTarget.refusals/0`, each already recorded by CYFR as a
  denial of the attempt), or `{:error, :lost | :unavailable}`. A request
  `Prima.PinnedTarget.request_args/3` refuses is `{:error, :malformed}`
  without a call. The call is idempotent: a lost answer is asked once
  more.
  """
  @spec egress_pin(t(), String.t(), keyword()) :: {:ok, PinnedTarget.t()} | {:error, term()}
  def egress_pin(%__MODULE__{} = client, url, opts \\ []) when is_binary(url) and is_list(opts) do
    purpose = Keyword.get(opts, :purpose, :fetch)

    with {:ok, args} <- pin_args(url, purpose, Keyword.get(opts, :from)),
         {:ok, wire} <- request(client, :egress_pin, args) do
      case PinnedTarget.read(wire) do
        {:ok, pin} -> {:ok, pin}
        :error -> {:error, :lost}
      end
    end
  end

  defp pin_args(url, purpose, from) when purpose in [:fetch, :stream, :redirect] do
    case PinnedTarget.request_args(url, purpose, from) do
      {:ok, args} -> {:ok, args}
      :error -> {:error, :malformed}
    end
  end

  defp pin_args(_url, _purpose, _from), do: {:error, :malformed}

  @doc """
  Report, for the worker service `credentials` name on its boot `boot`,
  that its runner `runner` exited while it held `attempts`. Every attempt
  one runner holds was issued by one member, so the report names that
  member (`at`) and is posted at its address; a member that is not the one
  named lapses nothing. The report is signed with the service's dispatch
  key. Answers `:ok`, or `{:error, :lost | :unavailable}`.
  """
  @spec runner_exited(
          Opus.Credentials.t(),
          %{member: String.t(), host_url: String.t()},
          String.t(),
          String.t(),
          [String.t()]
        ) :: :ok | {:error, term()}
  def runner_exited(%Opus.Credentials{} = credentials, at, boot, runner, attempts)
      when is_binary(boot) and is_binary(runner) and is_list(attempts) do
    body =
      Jason.encode!(
        WorkerWire.request_body(:runner_exited, %{
          "member" => at.member,
          "runner" => runner,
          "attempts" => attempts
        })
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

    case call({:http, at.host_url}, :runner_exited, try) do
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

    call(via(client), op, try)
  end

  defp via(%__MODULE__{relay: nil, host_url: host_url}), do: {:http, host_url}
  defp via(%__MODULE__{relay: relay, attempt: attempt}), do: {:relay, relay, attempt}

  # A child's attempt is carried on the runner's relay before its first
  # call; a client posting directly has no relay to tell.
  defp carried(%__MODULE__{relay: nil}, _attempt), do: :ok
  defp carried(%__MODULE__{relay: relay}, attempt), do: Opus.Relay.Runner.admit(relay, attempt)

  # One call: sealed and signed afresh for each try (`try` answers the
  # header, the body and how to read the answer), retried once after a
  # lost answer when its class allows, never on an answer CYFR gave.
  defp call(via, op, try) do
    answer =
      case post(via, op, try) do
        {:ok, answer} ->
          answer

        :lost ->
          case HostAPI.retry(op) do
            :never ->
              Logger.warning("[Opus.HostClient] #{op}'s answer was lost; its effect is uncertain")
              {:error, {:uncertain, @uncertain}}

            _retried ->
              Logger.warning("[Opus.HostClient] #{op}'s answer was lost; calling once more")

              case post(via, op, try) do
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

  defp post(via, op, try) do
    with {:ok, header, body, read} <- try.(),
         {:ok, raw} <- transport(via, op, header, body),
         {:ok, json} <- read.(raw) do
      answer(json, op)
    else
      {:refused, raw} -> refused(raw, op)
      _ -> :lost
    end
  end

  # A refusal by status is lost, unless it says the host speaks another
  # version of the wire: such a host refuses every call this engine makes,
  # so the call is answered as the refusal that stops the attempt's work
  # instead of being asked again. The refusal is plain, since a listener
  # that cannot read the header cannot seal to it, and is read whatever
  # version it carries, since it is the other version's answer.
  defp refused(raw, op) do
    case Jason.decode(raw) do
      {:ok, %{"error" => "unknown_version"}} -> other_version(op)
      _ -> :lost
    end
  end

  defp other_version(op) do
    Logger.warning(
      "[Opus.HostClient] #{op} was refused: the host speaks another version of the wire"
    )

    {:ok, {:error, :lost}}
  end

  # The bytes of a `200` answer, `{:refused, bytes}` for the body of any
  # other status, or `:error` for a transport failure, an answer past the
  # bound or later than the callback's timeout, whether the worker service
  # posted it for a runner's relay or itself. No answer body is logged.
  defp transport(via, op, header, body) do
    sent =
      case via do
        {:http, host_url} ->
          post_call(host_url, op, header, body)

        {:relay, relay, attempt} ->
          Opus.Relay.Runner.call(relay, attempt, op, header, body, HostAPI.request_timeout_ms(op))
      end

    case sent do
      {:ok, 200, raw} -> {:ok, raw}
      {:ok, status, raw} when is_integer(status) -> {:refused, raw}
      _lost -> :error
    end
  end

  @typedoc """
  What `attached_fetch/3` hands its caller, in order: CYFR's refusal of the
  request before its admission, as the header posted and the sealed answer
  received, or each frame of an admitted request's answer as CYFR sealed
  it, its kind byte and sealed value without the length prefix.
  """
  @type attached_event :: {:refusal, String.t(), binary()} | {:frame, binary()}

  @doc """
  Post a guest's attached request (`c:Prima.HostAPI.attached_fetch/3`) for
  this client's attempt, once, and hand its answer to `sink` as it
  arrives, unopened (`t:attached_event/0`). The call is sealed and signed
  as every host call is, under the attempt's keys, and is never asked
  again: its effect may have happened.

  A `200` answer of `Prima.WorkerWire.attached_frames_content_type/0` is
  split into frames (`Prima.WorkerAuth.split_frames/1`), each handed over
  as it completes, and nothing more is read until `sink` answers: `:ok`
  reads on, and `:halt` stops and closes the connection. Any other `200`
  answer is CYFR's refusal, read whole within
  `Prima.HostAPI.max_answer_bytes/0` and handed over once. The chunk
  frames' body bytes (`Prima.WorkerAuth.frame_body_bytes/1`) are bounded
  by `max_response_size`, and every wait by `deadline`, in milliseconds
  since the epoch.

  Answers `:ok` once the answer was handed over whole, `:halted` when
  `sink` stopped it, or `{:error, code}`: `"lost"` for any status but
  `200`; `"uncertain"` when no status reached this service (a transport
  failure, a timeout, or a refusal past its bound); `"timeout"` for the
  deadline passing after the status; `"response_too_large"`; `"bad_frame"`
  for a length `split_frames/1` refuses or a body ending inside a frame;
  and `"http_error"` for a transport failure after the status. No frame
  is opened here and no body is logged.
  """
  @spec attached_fetch(t(), AttachedRequest.t(), %{
          sink: (attached_event() -> :ok | :halt),
          max_response_size: pos_integer(),
          deadline: integer()
        }) :: :ok | :halted | {:error, String.t()}
  def attached_fetch(
        %__MODULE__{relay: nil} = client,
        %AttachedRequest{} = request,
        %{sink: sink, max_response_size: max, deadline: deadline}
      )
      when is_function(sink, 1) and is_integer(max) and max > 0 and is_integer(deadline) do
    json =
      Jason.encode!(WorkerWire.request_body(:attached_fetch, AttachedRequest.to_args(request)))

    fields = call_fields(client)

    with {:ok, sealed} <- WorkerAuth.seal_call(client.seal_key, :body, fields, json),
         {:ok, header} <- WorkerAuth.host_call_header(client.call_key, fields, sealed) do
      caller = self()
      ref = make_ref()

      # The request is read in a process of its own, so every wait here is
      # bounded by the deadline whatever the connection does; it hands each
      # piece of the answer over and reads on only when told.
      reader =
        spawn_link(fn ->
          read_attached(caller, ref, client.host_url, header, sealed, deadline)
        end)

      state = %{
        reader: reader,
        ref: ref,
        sink: sink,
        header: header,
        max: max,
        deadline: deadline,
        status: nil,
        frames?: false,
        buffer: "",
        bytes: 0
      }

      try do
        attached_answer(state)
      after
        stop_reader(reader, ref)
      end
    else
      _unsealable -> {:error, "lost"}
    end
  end

  # Each piece of the answer is told to the caller, and the next is read
  # only once the caller asks for it; a caller that stops reading kills
  # this process, which closes the connection.
  defp read_attached(caller, ref, host_url, header, body, deadline) do
    timeout = max(deadline - System.system_time(:millisecond), 1)

    into = fn {:data, data}, {req, resp} ->
      send(caller, {ref, :data, resp.status, frames?(resp), data})

      receive do
        {^ref, :more} -> {:cont, {req, resp}}
      end
    end

    result =
      Req.request(
        method: :post,
        url: host_url <> WorkerWire.host_route(:attached_fetch),
        headers: [{WorkerWire.auth_header(), header}, {"content-type", "application/json"}],
        body: body,
        receive_timeout: timeout,
        connect_options: [timeout: timeout],
        retry: false,
        redirect: false,
        compressed: false,
        decode_body: false,
        into: into
      )

    ended =
      case result do
        {:ok, %Req.Response{status: status} = resp} -> {:answered, status, frames?(resp)}
        {:error, %Req.TransportError{reason: :timeout}} -> :timeout
        {:error, _exception} -> :failed
      end

    send(caller, {ref, :done, ended})
  end

  defp frames?(%Req.Response{} = resp) do
    resp
    |> Req.Response.get_header("content-type")
    |> Enum.any?(fn type ->
      type |> String.split(";") |> hd() |> String.trim() |> String.downcase() ==
        WorkerWire.attached_frames_content_type()
    end)
  end

  defp attached_answer(%{ref: ref} = state) do
    receive do
      {^ref, :data, status, frames?, data} ->
        on_attached_data(%{state | status: status, frames?: frames?}, data)

      {^ref, :done, ended} ->
        on_attached_done(state, ended)
    after
      max(state.deadline - System.system_time(:millisecond), 0) -> past_deadline(state)
    end
  end

  # No status reached this service before the deadline: what CYFR did is
  # unknown. After it, the deadline ended the answer.
  defp past_deadline(%{status: nil}), do: {:error, "uncertain"}
  defp past_deadline(_state), do: {:error, "timeout"}

  defp on_attached_data(%{status: 200, frames?: true} = state, data) do
    if System.system_time(:millisecond) >= state.deadline do
      {:error, "timeout"}
    else
      case WorkerAuth.split_frames(state.buffer <> data) do
        {:ok, frames, rest} -> hand_frames(%{state | buffer: rest}, frames)
        {:error, _refusal} -> {:error, "bad_frame"}
      end
    end
  end

  defp on_attached_data(%{status: 200} = state, data) do
    buffer = state.buffer <> data

    if byte_size(buffer) > HostAPI.max_answer_bytes(),
      do: {:error, "uncertain"},
      else: read_on(%{state | buffer: buffer})
  end

  defp on_attached_data(_state, _data), do: {:error, "lost"}

  defp hand_frames(state, []), do: read_on(state)

  defp hand_frames(state, [frame | frames]) do
    bytes = state.bytes + WorkerAuth.frame_body_bytes(frame)

    if bytes > state.max do
      {:error, "response_too_large"}
    else
      case state.sink.({:frame, frame}) do
        :ok -> hand_frames(%{state | bytes: bytes}, frames)
        :halt -> :halted
      end
    end
  end

  defp read_on(state) do
    send(state.reader, {state.ref, :more})
    attached_answer(state)
  end

  defp on_attached_done(state, {:answered, 200, true}) do
    if state.buffer == "", do: :ok, else: {:error, "bad_frame"}
  end

  defp on_attached_done(state, {:answered, 200, false}) do
    _ = state.sink.({:refusal, state.header, state.buffer})
    :ok
  end

  defp on_attached_done(_state, {:answered, _status, _frames?}), do: {:error, "lost"}
  defp on_attached_done(%{status: nil}, _failed), do: {:error, "uncertain"}
  defp on_attached_done(_state, :timeout), do: {:error, "timeout"}
  defp on_attached_done(_state, :failed), do: {:error, "http_error"}

  # The reader is stopped on every way out, which closes its connection
  # unless the answer was read to its end, and nothing it sent is left
  # behind.
  defp stop_reader(reader, ref) do
    Process.unlink(reader)
    Process.exit(reader, :kill)
    flush(ref, reader)
  end

  defp flush(ref, reader) do
    receive do
      {^ref, :data, _status, _frames?, _data} -> flush(ref, reader)
      {^ref, :done, _ended} -> flush(ref, reader)
      {:EXIT, ^reader, _reason} -> flush(ref, reader)
    after
      0 -> :ok
    end
  end

  @doc """
  Post one host call of `op`, its signed `header` and its `body`, to the
  host API at `host_url`, once: CYFR's status and the answer's bytes, read
  up to `Prima.HostAPI.max_answer_bytes/0`, or `:error` for a transport
  failure, an answer past the bound or later than the callback's timeout.
  The worker service posts every host call with it, its runners' as their
  relay hands them over and its own.
  """
  @spec post_call(String.t(), atom(), String.t(), binary()) ::
          {:ok, 100..599, binary()} | :error
  def post_call(host_url, op, header, body)
      when is_binary(host_url) and is_binary(header) and is_binary(body) do
    max = HostAPI.max_answer_bytes()

    request = [
      method: :post,
      url: host_url <> WorkerWire.host_route(op),
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

    case Req.request(request) do
      {:ok, %Req.Response{status: status} = response} ->
        case BoundedBody.read(response, max) do
          {:ok, raw} -> {:ok, status, raw}
          _ -> :error
        end

      _ ->
        :error
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
      member: client.member,
      ts: System.system_time(:millisecond),
      nonce: nonce()
    }
  end

  defp at(%__MODULE__{relay: nil} = client),
    do: %{member: client.member, host_url: client.host_url}

  defp at(%__MODULE__{} = client), do: %{member: client.member, relay: client.relay}

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  # A child's assignment must name the attempt its keys open as, on this
  # client's worker service and boot, and be issued by the member its
  # parent's is: a child is admitted through the parent's host call, so a
  # child of another member's is a child this runner cannot reach. A
  # runner's client knows no address: its relay's service end holds the
  # child's to its parent's.
  defp names_attempt?(%Assignment{} = assignment, attempt, %__MODULE__{} = client) do
    Map.take(assignment, @attempt_fields) == Map.take(attempt, @attempt_fields) and
      assignment.service == client.service and assignment.boot == client.boot and
      attempt.service == client.service and assignment.member == client.member and
      (assignment.host_url == nil or client.host_url == nil or
         assignment.host_url == client.host_url)
  end

  defp outcome(client, status, fields) do
    Map.merge(fields, %{
      "execution_id" => client.execution_id,
      "attempt" => client.attempt,
      "fence" => client.fence,
      "status" => status
    })
  end

  # An answer CYFR gave to `op`, or `:lost` for bytes that are not one at
  # this wire's version (`Prima.WorkerWire.read_answer/1`).
  defp answer(json, op) do
    case Jason.decode(json) do
      {:ok, decoded} -> read_answer(decoded, op)
      {:error, _} -> :lost
    end
  end

  defp read_answer(decoded, op) do
    case WorkerWire.read_answer(decoded) do
      {:ok, value} ->
        {:ok, {:ok, value}}

      {:error, "setup_required", %{"payload" => %{} = payload}} ->
        {:ok, {:error, {:setup_required, payload}}}

      {:error, "guest_error", %{"type" => type, "message" => message} = fields}
      when is_binary(type) and is_binary(message) ->
        {:ok, guest_error(fields, type, message)}

      {:error, "failed", %{"message" => message}} when is_binary(message) ->
        {:ok, {:error, {:failed, message}}}

      {:error, "unknown_version", _fields} ->
        other_version(op)

      {:error, refusal, _fields} when is_map_key(@refusals, refusal) ->
        {:ok, {:error, Map.fetch!(@refusals, refusal)}}

      {:error, refusal, _fields} when op == :egress_pin and is_map_key(@pin_refusals, refusal) ->
        {:ok, {:error, Map.fetch!(@pin_refusals, refusal)}}

      _ ->
        :lost
    end
  end

  defp guest_error(%{"remediation" => %{} = remediation}, type, message),
    do: {:error, {:guest_error, type, message, remediation}}

  defp guest_error(_fields, type, message), do: {:error, {:guest_error, type, message}}

  defp renewal(%{"lease_until" => until}) when is_integer(until), do: {:ok, until}
  defp renewal(_lost), do: :lost
end
