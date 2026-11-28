# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.HostClient do
  @moduledoc """
  The worker service's poster of CYFR's host calls (`Prima.HostAPI`):
  every host call reaches CYFR from the worker service, never from a
  runner. A runner signs and seals its own calls under its attempt's keys
  and sends them through its relay, whose service end (`Locus.Runtime.Relay`)
  verifies each and posts it unchanged with `post_call/5`. The service's
  own calls for an attempt (the `take_rate` its relay takes and the
  `egress_pin` it asks before it connects a fetch, and an attached
  request, `attached_fetch/3`) are made by a client of this module for
  that attempt, and its reports (`runner_exited/7`, `report_events/3`)
  are signed with its own dispatch key.

  A client names the attempt (its athanor, execution, attempt id, fence,
  generation and worker service), the runner presenting it, the attempt's
  keys CYFR issued with the assignment, and **the member that issued that
  assignment**: its boot id and the base URL of its host API, both read
  from the assignment (`Prima.Assignment`). An attempt has one process, on
  that member, so its calls are posted at that member's address and name
  it in every header; a member that is not the one named refuses them,
  and an assignment naming no address is posted to the address this
  worker service is configured with (`Locus.Runtime.Credentials`), which is the
  whole deployment where only one member issues. Every call is one `POST`
  to the callback's route
  (`Prima.WorkerWire.host_route/1`): its body is the versioned JSON
  `{"v": 3, "op": name, "args": {...}}` (`Prima.WorkerWire.request_body/2`)
  sealed with the attempt's seal key to the call's fields
  (`Prima.WorkerAuth.seal_call/5`), and its `x-cyfr-auth` header is the
  attempt's call-key signature over those fields — a fresh nonce and the
  current time among them — and the sealed body
  (`Prima.WorkerAuth.host_call_header/3`). A `200` answer is the JSON
  `Prima.WorkerWire` describes, sealed to the same fields in the answer
  direction, read up to `Prima.HostAPI.max_answer_bytes/0` and read as an
  answer of this wire's version (`Prima.WorkerWire.read_answer/1`); an
  answer without `v`, or at another version, is no answer and is lost.
  A call the worker service posts itself reads its answer under the
  runtime's count (`Locus.Output.server(:runtime)`): room for twice the
  length the answer declares, or twice the answer bound, the answer and
  its opening, is asked for as its reading begins, by the call's own
  timeout, and given back once the answer is read and decoded; an answer
  no room came for by then is one that did not arrive.
  Any other status is the listener's refusal, and is lost, except two
  that are final: a `413`, whatever its body, says the call's body is past
  the host's bound (`Prima.HostAPI.max_body_bytes/0`), refused before the
  host read it or acted on it, and the call is answered
  `{:error, :too_large}` rather than asked again, since the same body is
  refused again (a body past that bound is answered so before it is
  sent); and a refusal naming `unknown_version` says the host speaks
  another version of the wire, so it is not this engine's host, and the
  call is answered `{:error, :lost}` at once rather than asked again.

  Each function answers as the `Prima.HostAPI` callback of the same name.
  An answer that does not arrive within `Prima.HostAPI.request_timeout_ms/1`,
  or cannot be read, is lost, and what the client does then is the
  callback's retry class (`Prima.HostAPI.retry/1`): an `:idempotent`
  call is made once more — the same body under a fresh header — and a
  `:never` call ends `{:error, {:uncertain, sentence}}`, since its effect
  may have happened, or `{:error, :unsent}` when no connection to CYFR
  could be made, since nothing of it was sent. A second loss is
  `{:error, :lost}`. CYFR's own answers, `lost` included, are never
  retried: they are answers, and so are the two final refusals.

  `egress_pin/3` asks CYFR for the address a guest's outbound URL may be
  reached at (`c:Prima.HostAPI.egress_pin/3`), and the relay connects to
  the address the answer names (`Locus.Runtime.Egress.connect_options/3`).

  `attached_fetch/3` posts a guest's request naming a connection, which
  CYFR makes itself with the credential attached, and hands the answer's
  sealed frames to its caller as they arrive, unopened: the worker
  service's relay posts it for its runner (`Locus.Runtime.Relay`), and only the
  runner opens the frames. Every other call is read whole.

  Two calls are the worker service's reports, each a plain JSON body
  signed with its dispatch key and answered in plain JSON:
  `runner_exited/7`, that one of its runners exited, posted to the
  member that assigned the runner its subtree, and `report_events/3`, a
  batch of its runners' operator events, posted to the address the
  service is configured with.

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
          member: String.t(),
          call_key: binary(),
          seal_key: binary(),
          host_url: String.t()
        }

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

  # What a connection that could not be made fails with: nothing of the
  # call was written.
  @unconnected [:econnrefused, :nxdomain, :ehostunreach, :enetunreach, :eaddrnotavail]

  # The count every answer the worker service reads is held under: its own
  # calls' here, its runners' in their relays (`Locus.Runtime.Relay`).
  @count Locus.Output.server(:runtime)
  # Where a call the service posts itself keeps its answer's grant while it
  # reads and decodes the answer.
  @held {__MODULE__, :held}

  @doc """
  A client for the attempt `keys` name (`t:Prima.WorkerAuth.attempt_keys/0`),
  signing with its call key, addressed to the member `at` names: its
  `member` boot id, which every header presents, and the `host_url` the
  worker service posts to. `runner` names the runner presenting the calls
  (a fresh runner id is minted when it is nil) and `boot` the worker
  service boot it presents from.
  """
  @spec new(
          Prima.WorkerAuth.attempt_keys(),
          String.t() | nil,
          String.t(),
          %{member: String.t(), host_url: String.t()}
        ) :: t()
  def new(
        %{attempt: attempt, call: call_key, seal: seal_key},
        runner,
        boot,
        %{member: member, host_url: url}
      )
      when is_map(attempt) and is_binary(call_key) and is_binary(seal_key) and is_binary(boot) and
             is_binary(member) and is_binary(url) do
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
      host_url: url
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
  that its runner `runner` exited while it held `attempts`, and with
  `refusal`, the code of the keeper's refusal of that runner after its
  start was answered, when CYFR has words for it
  (`Prima.WorkerAPI.runner_refusal/1`): any other is sent as none, which
  CYFR reads as no reason. `memory` is the memory limit that ended the
  runner (`t:Locus.Runtime.Keeper.ended_for_memory/0`), sent as
  `"cap"`, `"machine"` or `"either"`, and nil for a runner that ended
  otherwise, sent as none. Every attempt
  one runner holds was issued by one member, so the report names that
  member (`at`) and is posted at its address; a member that is not the one
  named lapses nothing. The report is signed with the service's dispatch
  key. Answers `:ok`, or `{:error, :lost | :unavailable | :too_large}`.
  """
  @spec runner_exited(
          Locus.Runtime.Credentials.t(),
          %{member: String.t(), host_url: String.t()},
          String.t(),
          String.t(),
          [String.t()],
          String.t() | nil,
          Locus.Runtime.Keeper.ended_for_memory()
        ) :: :ok | {:error, term()}
  def runner_exited(
        %Locus.Runtime.Credentials{} = credentials,
        at,
        boot,
        runner,
        attempts,
        refusal,
        memory
      )
      when is_binary(boot) and is_binary(runner) and is_list(attempts) do
    args = %{"member" => at.member, "runner" => runner, "attempts" => attempts}

    args =
      if Prima.WorkerAPI.runner_refusal(refusal),
        do: Map.put(args, "refusal", refusal),
        else: args

    args = Prima.HostAPI.put_memory_end(args, memory)

    body = Jason.encode!(WorkerWire.request_body(:runner_exited, args))

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

    case call(at.host_url, :runner_exited, try) do
      {:ok, true} -> :ok
      {:ok, _other} -> {:error, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Report, for the worker service `credentials` name on its boot `boot`,
  its runners' operator `events`, each an `event` frame a runner sent
  (`c:Prima.HostAPI.report_events/2`), as one batch of at most
  `Prima.HostAPI.max_report_events/0`: signed with the service's dispatch
  key and posted to the address the service is configured with, naming no
  member. A batch is never sent again: one whose answer was lost is
  `{:error, {:uncertain, sentence}}`, and one that reached no connection
  `{:error, :unsent}`, which its caller may send again. Answers `:ok`, or
  `{:error, reason}`.
  """
  @spec report_events(Locus.Runtime.Credentials.t(), String.t(), [
          Prima.RunnerControl.event(),
          ...
        ]) :: :ok | {:error, term()}
  def report_events(%Locus.Runtime.Credentials{} = credentials, boot, events)
      when is_binary(boot) and is_list(events) do
    body =
      Jason.encode!(
        WorkerWire.request_body(:report_events, HostAPI.report_events_args(events))
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

    case call(credentials.host_url, :report_events, try) do
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
    case post(host_url, op, try) do
      {:ok, answer} ->
        answer

      lost ->
        case HostAPI.retry(op) do
          # Nothing of a call that reached no connection was sent, so
          # nothing of it happened.
          :never when lost == :unsent ->
            {:error, :unsent}

          :never ->
            Logger.warning(
              "[Locus.Runtime.HostClient] #{op}'s answer was lost; its effect is uncertain"
            )

            {:error, {:uncertain, @uncertain}}

          _retried ->
            Logger.warning(
              "[Locus.Runtime.HostClient] #{op}'s answer was lost; calling once more"
            )

            case post(host_url, op, try) do
              {:ok, answer} -> answer
              _lost -> {:error, :lost}
            end
        end
    end
  end

  defp post(host_url, op, try) do
    with {:ok, header, body, read} <- try.(),
         :ok <- within_bound(body),
         {:ok, raw} <- transport(host_url, op, header, body),
         {:ok, json} <- read.(raw) do
      answer(json, op)
    else
      {:refused, 413, _raw} -> too_large(op)
      :too_large -> too_large(op)
      {:refused, _status, raw} -> refused(raw, op)
      :unsent -> :unsent
      _ -> :lost
    end
  after
    let_go()
  end

  # A call the service posts itself: its answer is asked for under the
  # runtime's count as its reading begins, whole, for the answer and its
  # opening, by the call's own timeout (`post_call/5`). The pieces it was
  # read in are collected before it is opened, so it is held at most
  # twice over until it is decoded (`post/3`).
  defp own_call(host_url, op, header, body) do
    by = System.monotonic_time(:millisecond) + HostAPI.request_timeout_ms(op)

    room = fn bytes ->
      case Locus.Output.reserve(@count, 2 * bytes, by) do
        {:ok, grant} ->
          Process.put(@held, grant)
          :ok

        :full ->
          :full
      end
    end

    sent = post_call(host_url, op, header, body, room: room)
    :erlang.garbage_collect()
    sent
  end

  # The answer of a call the service posted itself is gone once it is
  # read and decoded: what is left of it is collected, then its grant goes
  # back.
  defp let_go do
    case Process.delete(@held) do
      nil ->
        :ok

      grant ->
        :erlang.garbage_collect()
        Locus.Output.return(grant)
    end
  end

  # A body past the host's bound is never sent: the host would refuse it
  # `413`, so it is refused here.
  defp within_bound(body),
    do: if(byte_size(body) > HostAPI.max_body_bytes(), do: :too_large, else: :ok)

  # A body past the host's bound is refused before the host reads it, so
  # nothing was done, and the same body is refused again: the refusal is
  # the call's answer, never retried, whatever its body says.
  defp too_large(op) do
    Logger.warning(
      "[Locus.Runtime.HostClient] #{op} was refused: its body is past the host's bound"
    )

    {:ok, {:error, :too_large}}
  end

  # A refusal by any other status is lost, unless it says the host speaks
  # another version of the wire: such a host refuses every call this
  # engine makes, so the call is answered as the refusal that stops the
  # attempt's work instead of being asked again. The refusal is plain,
  # since a listener that cannot read the header cannot seal to it, and is
  # read whatever version it carries, since it is the other version's
  # answer.
  defp refused(raw, op) do
    case Jason.decode(raw) do
      {:ok, %{"error" => "unknown_version"}} -> other_version(op)
      _ -> :lost
    end
  end

  defp other_version(op) do
    Logger.warning(
      "[Locus.Runtime.HostClient] #{op} was refused: the host speaks another version of the wire"
    )

    {:ok, {:error, :lost}}
  end

  # The bytes of a `200` answer, `{:refused, status, bytes}` for any other
  # status and its body (none of a body past the bound), or `:error` for a
  # transport failure, a `200` answer past the bound or one later than the
  # callback's timeout. No answer body is logged.
  defp transport(host_url, op, header, body) do
    case own_call(host_url, op, header, body) do
      {:ok, 200, raw} -> {:ok, raw}
      {:ok, status, raw} when is_integer(status) -> {:refused, status, raw}
      :unsent -> :unsent
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
  `Prima.HostAPI.max_answer_bytes/0` and handed over once, and a `sink`
  that halts it halts the answer as it halts a frame. The refusal's room,
  `:room` (a function of the bytes it may hold, as `post_call/5`'s), is
  asked once, as its first piece is read and before it is kept, for the
  whole refusal: the length it declares, or the answer bound when it
  declares none or more. `:ok` keeps it; `:full` halts the answer. With no
  `:room`, nothing is asked. The chunk
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
          required(:sink) => (attached_event() -> :ok | :halt),
          required(:max_response_size) => pos_integer(),
          required(:deadline) => integer(),
          optional(:room) => (pos_integer() -> :ok | :full)
        }) :: :ok | :halted | {:error, String.t()}
  def attached_fetch(
        %__MODULE__{} = client,
        %AttachedRequest{} = request,
        %{sink: sink, max_response_size: max, deadline: deadline} = options
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
        room: Map.get(options, :room),
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

  # Each piece of the answer is told to the caller, with the length the
  # answer declares, and the next is read only once the caller asks for
  # it; a caller that stops reading kills this process, which closes the
  # connection. The connection is made under the host calls' own connect
  # options (`post_call/5`'s), whatever the deadline: the HTTP client keeps
  # a pool for each set of them it is given.
  defp read_attached(caller, ref, host_url, header, body, deadline) do
    timeout = max(deadline - System.system_time(:millisecond), 1)

    into = fn {:data, data}, {req, resp} ->
      declared = declared(resp, HostAPI.max_answer_bytes())
      send(caller, {ref, :data, resp.status, frames?(resp), declared, data})

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
        connect_options: [
          timeout: HostAPI.request_timeout_ms(:attached_fetch),
          transport_opts: Locus.Runtime.Egress.transport_opts()
        ],
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

  defp frames?(%Req.Response{} = resp),
    do: resp |> Req.Response.get_header("content-type") |> WorkerWire.frames_content_type?()

  defp attached_answer(%{ref: ref} = state) do
    receive do
      {^ref, :data, status, frames?, declared, data} ->
        on_attached_data(%{state | status: status, frames?: frames?}, declared, data)

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

  defp on_attached_data(%{status: 200, frames?: true} = state, _declared, data) do
    if System.system_time(:millisecond) >= state.deadline do
      {:error, "timeout"}
    else
      case WorkerAuth.split_frames(state.buffer <> data) do
        {:ok, frames, rest} -> hand_frames(%{state | buffer: rest}, frames)
        {:error, _refusal} -> {:error, "bad_frame"}
      end
    end
  end

  # CYFR's refusal: its room is asked with its first piece in hand, before
  # any of it is kept, for the whole of it; no room halts the answer.
  defp on_attached_data(%{status: 200} = state, declared, data) do
    case roomed(state, declared) do
      {:ok, state} ->
        buffer = state.buffer <> data

        if byte_size(buffer) > HostAPI.max_answer_bytes(),
          do: {:error, "uncertain"},
          else: read_on(%{state | buffer: buffer})

      :full ->
        :halted
    end
  end

  defp on_attached_data(_state, _declared, _data), do: {:error, "lost"}

  defp roomed(%{room: room} = state, declared) when is_function(room, 1) do
    case room.(declared) do
      :ok -> {:ok, %{state | room: nil}}
      :full -> :full
    end
  end

  defp roomed(state, _declared), do: {:ok, state}

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
    case state.sink.({:refusal, state.header, state.buffer}) do
      :ok -> :ok
      :halt -> :halted
    end
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
      {^ref, :data, _status, _frames?, _declared, _data} -> flush(ref, reader)
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
  failure, a `200` answer past the bound or an answer later than the
  callback's timeout, and `:unsent` for a connection to `host_url` that
  could not be made, so nothing of the call was sent. A refusal, any
  other status, whose body runs past the bound keeps its status, with
  none of its body: the status is what a refusal says. The worker service
  posts every host call with it, its runners' as their relay hands them
  over and its own.

  `:room`, a function of the bytes an answer may hold, is asked once, as
  the answer's first piece is read and before it is kept, for the whole
  answer: the length it declares, or the answer bound when it declares
  none or more. `:ok` keeps it; `:full` stops the read and closes the
  connection, and the answer is then one that did not arrive, as an
  answer past the bound is. An answer with no body asks for nothing.
  """
  @spec post_call(String.t(), atom(), String.t(), binary(), [
          {:room, (pos_integer() -> :ok | :full)}
        ]) :: {:ok, 100..599, binary()} | :unsent | :error
  def post_call(host_url, op, header, body, opts \\ [])
      when is_binary(host_url) and is_binary(header) and is_binary(body) and is_list(opts) do
    max = HostAPI.max_answer_bytes()

    request = [
      method: :post,
      url: host_url <> WorkerWire.host_route(op),
      headers: [{WorkerWire.auth_header(), header}, {"content-type", "application/json"}],
      body: body,
      receive_timeout: HostAPI.request_timeout_ms(op),
      connect_options: [
        timeout: HostAPI.request_timeout_ms(op),
        transport_opts: Locus.Runtime.Egress.transport_opts()
      ],
      retry: false,
      redirect: false,
      compressed: false,
      decode_body: false,
      into: collector(max, Keyword.get(opts, :room))
    ]

    case Req.request(request) do
      {:ok, %Req.Response{status: status} = response} ->
        case {Req.Response.get_private(response, :room), BoundedBody.read(response, max)} do
          {:full, _read} when status != 200 ->
            {:ok, status, ""}

          {:full, _read} ->
            :error

          {_room, {:ok, raw}} ->
            {:ok, status, raw}

          {_room, {:error, {:response_too_large, _seen, _max}}} when status != 200 ->
            {:ok, status, ""}

          {_room, {:error, {:response_too_large, _seen, _max}}} ->
            :error
        end

      {:error, %Req.TransportError{reason: reason}} when reason in @unconnected ->
        :unsent

      _ ->
        :error
    end
  end

  defp collector(max, nil), do: BoundedBody.collector(max)

  # The room is asked for the whole answer at once, never piece by piece:
  # answers that each held part of the room while waiting for the rest
  # could hold all of it, and none would finish.
  defp collector(max, room) when is_function(room, 1) do
    collect = BoundedBody.collector(max)

    fn {:data, data}, {req, resp} ->
      case Req.Response.get_private(resp, :room) do
        :ok ->
          collect.({:data, data}, {req, resp})

        nil ->
          case room.(declared(resp, max)) do
            :ok -> collect.({:data, data}, {req, Req.Response.put_private(resp, :room, :ok)})
            :full -> {:halt, {req, Req.Response.put_private(resp, :room, :full)}}
          end
      end
    end
  end

  # The most an answer may hold: the length it declares, or the answer
  # bound, past which nothing of it is kept.
  defp declared(resp, max) do
    case Req.Response.get_header(resp, "content-length") do
      [length] -> declared_within(Integer.parse(length), max)
      _none_or_more -> max
    end
  end

  defp declared_within({bytes, ""}, max) when bytes in 1..max//1, do: bytes
  defp declared_within(_unread, max), do: max

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

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

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
end
