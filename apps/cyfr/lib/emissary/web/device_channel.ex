# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.DeviceChannel do
  @moduledoc """
  The device channel: a paired glass's own socket, carrying the device
  protocol (`Prima.Device`) and nothing else.

  It is a raw WebSocket under `Phoenix.Socket.Transport`, one
  `cyfr-device/v1` JSON message per text frame with no channel envelope,
  so `tests/fixtures/device.json` is the wire. The endpoint mounts it at
  `/device` (`/device/websocket`), carrying the peer's address and the
  proxy headers and nothing else: it reads no session and no cookie, so a
  cookie the browser holds never chooses the person.

  ## The sequence

  The upgrade admits nothing. The glass sends `connect`, naming its client
  id and the certificate it connects under, and the home answers a
  `challenge` for purpose `connect` (`Prima.DeviceCert.Challenge`) bound
  to this home, the certificate's athanor and device key and the client
  id. The glass answers with a `proof`, which goes to the verifier with
  the connect and the challenge held for this connection. Until a proof
  verifies, the channel takes `connect` and `proof` and nothing else; the
  challenge's lifetime bounds how long it waits, from the upgrade and
  again from the challenge. Once a proof verifies, the channel holds the
  client's context, and each discrete `intent` is dispatched through the
  gate under it, one call id each, and answered with its `id` and exactly
  one of `result` or `error`.

  The verifier is not built: it refuses every proof as `:not_built`, so
  every connection is refused at its proof and no intent is dispatched.

  ## Refusals

  Each refusal is one admission decision, recorded under the call id the
  channel assigned the message it refuses, on the external plane, under
  the client's identity once one is established and under none before,
  with the class `unauthenticated`. Then the socket closes with a
  WebSocket close code whose reason is that class:

    * `4400` — a frame that does not decode as a `Prima.Device` message a
      glass sends: over 131,072 bytes (refused before it is read), not a
      text frame, not JSON, another version, a home's type, an unknown or
      missing field, or an intent carrying continuous data, refused by
      its shape before anything is dispatched.
    * `4401` — a refused or missing proof, a proof after its challenge
      expired, a second `connect`, or anything but `connect` and `proof`
      before a proof verified. An intent, a repeated confirmation among
      them, is answered first with its `id` and an `error` naming the
      class.

  `4403` (the client's standing ended) and `4408` (its certificate
  expired unrenewed) are reserved for the verified client; the glass reads
  these four codes and no others, and any other close as a lost
  connection.

  A refusal closes the channel for good. The transport sends the close
  frame but keeps delivering frames and timers until the peer's close or
  its read timeout, so the refusal cancels the deadline and marks the
  state closed, and from then on the channel records nothing and acts on
  nothing: one refused connection is one decision. A close the transport
  makes itself (a protocol error, bad UTF-8, a frame over the mount's cap,
  the idle timeout) records none, as a malformed HTTP request the server
  refuses records none.

  ## The context

  `connect/1` builds the unauthenticated context the channel holds, with
  `origin: :interactive` whatever the upgrade's query says: a decoded
  message cannot carry an origin, since `Prima.Device` refuses a field its
  type does not name, and the query is never read.
  """

  @behaviour Phoenix.Socket.Transport

  alias Prima.Device
  alias Prima.DeviceCert.Challenge
  alias Sanctum.Context

  # The close codes: a frame the protocol refuses by its shape, and a
  # connection that has not proven its key.
  @malformed 4400
  @unproven 4401

  @refused_class "unauthenticated"

  # The largest frame read: twice the largest valid glass message, a
  # maximal intent of 65,840 bytes. The mount caps a single frame at the
  # same size, but the transport reassembles a fragmented message far past
  # it before this channel sees it.
  @max_frame_bytes 131_072

  @typedoc """
  The channel's state:

    * `ctx` — the unauthenticated context `connect/1` built: this
      connection's request id and address, `origin: :interactive`.
    * `client` — the client's context once a proof verified, nil before.
    * `connect` — the `connect` message's body, `client_id` and
      `certificate`, once it arrived.
    * `challenge` — the challenge held for this connection, nil before
      `connect` and once a proof verified.
    * `deadline` — the token and timer of the deadline the proof must
      arrive before, nil once a proof verified or the channel closed.
    * `call_id` — the call id the channel assigned the message it decided
      last.
    * `closed` — true once a refusal closed the channel: nothing after it
      is recorded or acted on.
  """
  @type state :: %{
          ctx: Context.t(),
          client: Context.t() | nil,
          connect: %{client_id: String.t(), certificate: Prima.DeviceCert.t()} | nil,
          challenge: Challenge.t() | nil,
          deadline: {reference(), reference()} | nil,
          call_id: String.t() | nil,
          closed: boolean()
        }

  @impl true
  def child_spec(_opts), do: :ignore

  @impl true
  def connect(%{connect_info: connect_info}) do
    ctx =
      Context.build(
        request_id: Prima.UUID7.request_id(),
        client_ip: Sanctum.ClientIp.from_connect_info(connect_info),
        origin: :interactive
      )

    {:ok,
     %{
       ctx: ctx,
       client: nil,
       connect: nil,
       challenge: nil,
       deadline: nil,
       call_id: nil,
       closed: false
     }}
  end

  @impl true
  def init(state) do
    Prima.LoggerContext.set_request_id(state.ctx.request_id)
    {:ok, arm(state, Challenge.lifetime_ms())}
  end

  @impl true
  def handle_in(_frame, %{closed: true} = state), do: {:ok, state}

  def handle_in({frame, opts}, state) do
    state = %{state | call_id: Prima.UUID7.generate_id("call")}

    with :ok <- bounded(frame),
         :text <- Keyword.get(opts, :opcode),
         {:ok, map} <- Prima.Json.decode(frame),
         {:ok, message} <- Device.decode(map, :glass) do
      receive_message(message, state)
    else
      :oversize -> refuse(state, @malformed, :oversize_frame)
      _malformed -> refuse(state, @malformed, :malformed_frame)
    end
  end

  @impl true
  def handle_info(_message, %{closed: true} = state), do: {:ok, state}

  def handle_info(
        {__MODULE__, :deadline, token},
        %{deadline: {token, _timer}, client: nil} = state
      ),
      do: refuse(%{state | call_id: Prima.UUID7.generate_id("call")}, @unproven, :proof_missing)

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Before a proof verified: `connect`, then `proof`, and nothing else.
  # ---------------------------------------------------------------------------

  defp receive_message({:connect, body}, %{client: nil, connect: nil} = state) do
    case challenge(body) do
      {:ok, challenge} ->
        state = arm(%{state | connect: body, challenge: challenge}, challenge.expires_at - now())
        {:reply, :ok, {:text, wire({:challenge, %{challenge: challenge}})}, state}

      {:error, _unchallengeable} ->
        refuse(state, @unproven, :unchallengeable)
    end
  end

  defp receive_message({:proof, %{proof: proof}}, %{client: nil} = state) do
    cond do
      is_nil(state.challenge) -> refuse(state, @unproven, :proof_unchallenged)
      now() >= state.challenge.expires_at -> refuse(state, @unproven, :proof_expired)
      true -> prove(proof, state)
    end
  end

  # An intent before a proof, a repeated confirmation among them, is
  # answered before the close, and its decision names the operation.
  defp receive_message({:intent, %{id: id, operation: operation}}, %{client: nil} = state) do
    refuse(state, @unproven, :proof_missing,
      operation: operation,
      frames: [answer_refused(id, :proof_missing)]
    )
  end

  defp receive_message({:connect, _body}, state), do: refuse(state, @unproven, :second_connect)

  defp receive_message({_type, _body}, %{client: nil} = state),
    do: refuse(state, @unproven, :proof_missing)

  # Once a proof verified: each discrete intent through the gate, and
  # nothing else.
  defp receive_message({:intent, intent}, state), do: dispatch(intent, state)
  defp receive_message({_type, _body}, state), do: refuse(state, @unproven, :not_accepted)

  # The challenge for this connection's connect: this home, the
  # certificate's athanor and device key, the client id the glass named,
  # and a nonce drawn here.
  defp challenge(%{client_id: client_id, certificate: certificate}) do
    Challenge.new(
      purpose: :connect,
      home: Sanctum.origin(),
      athanor: certificate.athanor,
      client_id: client_id,
      device_key: certificate.device_key,
      nonce: :crypto.strong_rand_bytes(Challenge.nonce_bytes()),
      now: now()
    )
  end

  # A verified proof is what sets the client; the verifier answers no
  # verified proof yet, so the only answer here is its refusal.
  defp prove(proof, state) do
    case verify_connect(state.connect, proof, state.challenge) do
      {:error, _refused} -> refuse(state, @unproven, :proof_refused)
    end
  end

  # The verifier: the proof of possession under the certificate's device
  # key, the certificate and the paired client's standing. Not built:
  # every proof is refused.
  defp verify_connect(_connect, _proof, _challenge), do: {:error, :not_built}

  defp dispatch(%{id: id, operation: operation, args: args} = intent, state) do
    {tool, action} = names(operation)

    ctx = %{
      state.client
      | request_id: state.ctx.request_id,
        call_id: state.call_id,
        confirmation_id: Map.get(intent, :confirmation_id),
        origin: :interactive
    }

    answer =
      case Grimoire.call_external(tool, ctx, Map.put(args, "action", action),
             call_id: state.call_id,
             method: "device/intent"
           ) do
        {:ok, result} -> %{id: id, result: result}
        {:error, reason} -> %{id: id, error: error(reason)}
      end

    {:reply, :ok, {:text, wire({:answer, answer})}, state}
  end

  # A consent signal is answered in its own `{tag, payload}` shape; every
  # other refusal by its class and sentence.
  defp error(reason) do
    refusal = Grimoire.classify(reason)

    if Prima.ConsentSignal.signal?(refusal.reason),
      do: Prima.ConsentSignal.data(refusal.reason),
      else: %{"class" => Atom.to_string(refusal.class), "message" => refusal.message}
  end

  # ---------------------------------------------------------------------------
  # Refusals: one decision each, then the close.
  # ---------------------------------------------------------------------------

  # One decision under the call id assigned the refused message, under
  # the client's identity once one is established and none before, naming
  # the operation an intent gave; then the close, after `:frames`. The
  # state is closed for good first, its deadline cancelled, so a frame or
  # a timer the transport still delivers before the peer's close records
  # nothing.
  defp refuse(state, code, reason, opts \\ []) do
    cancel(state.deadline)
    state = %{state | deadline: nil, closed: true}
    {tool, action} = names(Keyword.get(opts, :operation))

    decision =
      Grimoire.refused_decision(state.client, refusal(reason),
        call_id: state.call_id,
        request_id: state.ctx.request_id,
        plane: :external,
        tool: tool,
        action: action
      )

    Grimoire.open_decision(state.client, decision, %{method: "device", input: %{}})
    close(state, code, Keyword.get(opts, :frames, []))
  end

  defp close(state, code, []), do: {:stop, :normal, {code, @refused_class}, state}
  defp close(state, code, frames), do: {:stop, :normal, {code, @refused_class}, frames, state}

  defp answer_refused(id, reason) do
    refusal = refusal(reason)
    error = %{"class" => Atom.to_string(refusal.class), "message" => refusal.message}
    {:text, wire({:answer, %{id: id, error: error}})}
  end

  defp refusal(reason) do
    %Prima.Refusal{
      class: :unauthenticated,
      reason: reason,
      message: sentence(reason),
      stage: :admission
    }
  end

  defp sentence(:oversize_frame), do: "The frame is larger than any device protocol message"
  defp sentence(:malformed_frame), do: "The frame is not a device protocol message a glass sends"
  defp sentence(:proof_missing), do: "The device has not proven its key on this connection"
  defp sentence(:proof_unchallenged), do: "The proof answers no challenge this connection holds"
  defp sentence(:proof_expired), do: "The proof arrived after its challenge expired"
  defp sentence(:proof_refused), do: "The device's proof of its key was refused"
  defp sentence(:second_connect), do: "This connection has already presented its certificate"
  defp sentence(:unchallengeable), do: "This home cannot challenge the device's certificate"
  defp sentence(:not_accepted), do: "This connection does not take that message"

  # ---------------------------------------------------------------------------
  # Plumbing
  # ---------------------------------------------------------------------------

  # A frame is read only within the bound; anything but bytes is no frame
  # this channel reads.
  defp bounded(frame) when is_binary(frame) and byte_size(frame) > @max_frame_bytes,
    do: :oversize

  defp bounded(frame) when is_binary(frame), do: :ok
  defp bounded(_frame), do: :malformed

  # `tool.action`, as the decision and the gate name it.
  defp names(nil), do: {nil, nil}

  defp names(operation) do
    [tool, action] = String.split(operation, ".", parts: 2)
    {tool, action}
  end

  # The proof must arrive within `ms`: a timer whose token the state
  # holds, replacing the one before, so a stale timer decides nothing.
  defp arm(state, ms) do
    cancel(state.deadline)
    token = make_ref()
    timer = Process.send_after(self(), {__MODULE__, :deadline, token}, max(ms, 0))
    %{state | deadline: {token, timer}}
  end

  defp cancel({_token, timer}), do: Process.cancel_timer(timer)
  defp cancel(nil), do: false

  defp wire(message), do: message |> Device.encode() |> Jason.encode!()

  defp now, do: System.system_time(:millisecond)
end
