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
  to the certificate's home, athanor and device key and the client id.
  The glass answers with a `proof`, which `Sanctum.DeviceCerts.verify_connect/3`
  decides with the connect and the challenge held for this connection:
  the proof of possession of the certificate's device key, then the
  certificate, under the person's current live key at this home, and the
  paired client's standing. Until a proof verifies, the channel takes
  `connect`, `renew` and `proof` and nothing else; the challenge's
  lifetime bounds how long it waits, from the upgrade and again from the
  challenge. A verified proof sets the client's context
  (`auth_method: :device`, its `client_id`), and the home answers
  `standing`: the client, its athanor and its certificate's expiry.

  Each discrete `intent` after that is checked first
  (`Sanctum.DeviceCerts.verify_request/3`: the certificate strictly
  unexpired on this home's clock, still chained to the person's current
  live key, and the paired client and its person still standing, read
  anew), then dispatched through the gate under the client's context,
  one call id each, and answered with its `id` and exactly one of
  `result` or `error`. Nothing is dispatched on a validation the channel
  remembers.

  ## Streams

  The channel is the delivery owner of a stream its client opens. The
  intent `streams.open`, with `args` `{stream, subject?}` (the tincture
  data routes' stream-open shape), is checked like every intent and then
  admitted by the gate's stream entry (`Grimoire.open_stream/3`), which
  records it. An admitted open is answered `answer` with
  `result: {grant_id}`, then `grant`, naming the stream, its subject, the
  fields it forwards and when it ends; a refused one is answered with its
  `error`, and the channel stays open. Each fact of the granted topic
  (`Cyfr.Bus.granted_topic/2`) is forwarded as `event`, projected to the
  grant's fields, by a forwarder process per grant that ends with the
  channel. A connection holds at most 16 grants.

  A stream ends, with `revoke` naming its grant:

    * at its deadline, which is never later than the certificate it was
      opened under; the channel stays open, and the glass opens it again;
    * on overflow: a channel whose mailbox holds more than 1,000 messages
      has fallen too far behind to deliver faithfully, and every grant is
      revoked rather than a fact dropped;
    * when its fact cannot be delivered because the store cannot vouch
      for the client now: that grant is revoked, never the fact dropped
      unannounced;
    * when the client's standing ends: each fact is delivered under a
      standing read within the freshness bound, a standing announcement
      about the person reads it again at once, and so does every intent
      and ping. A refusal revokes each grant, then, when the client's
      standing ended, the client's own pairing (`revoke` naming no grant),
      then closes `4403`; an expired certificate revokes each grant and
      closes `4408`.

  An admitted open whose forwarder cannot start is answered with an
  `unavailable` error and its grant revoked; the channel stays open.

  ## Renewal

  A glass renews with `renew`, naming its client and the certificate that
  locates it, and the home answers a `challenge` for purpose `renew`,
  bound like a connect's. On a connection that has proven nothing yet —
  a glass whose certificate expired, or was chained to a live key since
  rotated — that certificate only locates the client: the proof must be
  made by the device key the paired-client row stores, and the client and
  its person must stand (`Sanctum.DeviceCerts.verify_connect/3`). The
  channel then invokes `pairing/renew` through the gate, under the
  client's context, and that one operation alone: no message the glass
  sends is dispatched under it. The replacement certificate is checked
  as every request's is before anything else is admitted, and the home
  answers `certificate` and `standing`. On a verified connection the glass
  renews the same way under the certificate it stands under, and keeps
  working under that one until the replacement verifies. A challenge is
  answered once: a replayed proof finds none held, and the renewal
  consumes its proof once more, durably (`Sanctum.Pairing.renew/2`). An
  ordinary intent naming `pairing.renew` is answered with the refusal of
  its handler, which takes only the renewal exchange's context.

  A connect proof goes to the verifier, whose first step reads the
  connect bounds without counting, this node's and then the cell's, before
  any signature is checked (`Sanctum.DeviceCerts`); only a failed proof
  counts against them, and a renewal counts against the bounds pairing
  completions are held to. A spent bound closes with `1013`.

  ## Keeping the connection

  Once a proof verifies, the channel pings the glass every 30 seconds, so
  an idle glass's automatic pong keeps it inside the mount's 90-second
  read timeout (a browser cannot ping), and reads the client's standing
  again at each ping. The channel closes when the certificate it is
  bound to expires unrenewed, at that instant on this home's clock.

  ## Refusals

  Each refusal is one admission decision, recorded under the call id the
  channel assigned the message it refuses, on the external plane, under
  the client's identity once one is established and under none before,
  with its refusal class. Then the socket closes with a WebSocket close
  code whose reason is that class:

    * `4400` (`unauthenticated`) — a frame that does not decode as a
      `Prima.Device` message a glass sends: over 131,072 bytes (refused
      before it is read), not a text frame, not JSON, another version, a
      home's type, an unknown or missing field, or an intent carrying
      continuous data, refused by its shape before anything is
      dispatched.
    * `4401` (`unauthenticated`) — a refused or missing proof, a proof
      after its challenge expired, a second `connect`, a renewal refused,
      or anything but `connect`, `renew` and `proof` before a proof
      verified. An intent, a repeated confirmation among them, is
      answered first with its `id` and an `error` naming the class.
    * `4403` (`forbidden`) — the client's standing ended: its pairing
      revoked, its person denied, the athanor archived or the person no
      longer seated in it.
    * `4408` (`unauthenticated`) — the certificate expired unrenewed, or
      is no longer chained to the person's current live key: the glass
      renews.
    * `1013` — this home could not check the connection now: its store
      did not answer (reason `unavailable`), or a verification bound is
      spent (reason `rate_limited; retry_after_s=N`, the seconds until
      the bound opens again). The glass retries later, as it does after
      any close it does not read.

  A renewal the gate refused was recorded by the gate; the close records
  nothing more.

  A refusal closes the channel for good. The transport sends the close
  frame but keeps delivering frames, pings and timers until the peer's
  close or its read timeout, so the refusal cancels every timer and marks
  the state closed, and from then on the channel records nothing and acts
  on nothing: one refused connection is one decision. Anything that
  arrives after the close stops the connection, so a peer that keeps
  sending cannot hold the process. A close the transport makes itself (a
  protocol error, bad UTF-8, a frame over the mount's cap, the idle
  timeout) records none, as a malformed HTTP request the server refuses
  records none.

  ## The context

  `connect/1` builds the unauthenticated context the channel holds, with
  `origin: :interactive` whatever the upgrade's query says: a decoded
  message cannot carry an origin, since `Prima.Device` refuses a field its
  type does not name, and the query is never read. The client's context
  carries the same origin.
  """

  @behaviour Phoenix.Socket.Transport

  alias Cyfr.Bus.{AthanorArchived, Membership, Session}
  alias Emissary.Web.DeviceChannel.Forwarder
  alias Prima.{Device, DeviceCert, StreamGrant}
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.Identity.Encoding
  alias Sanctum.Context

  # The close codes: a frame the protocol refuses by its shape, a
  # connection that has not proven its key, a client whose standing
  # ended, a certificate that must be renewed, and a home that could not
  # check the connection now.
  @malformed 4400
  @unproven 4401
  @standing_ended 4403
  @renew 4408
  @try_again 1013

  # What the channel answers anything with once it closed: a stop the
  # transport ends the connection on, since the close frame is already
  # sent.
  @closed {:shutdown, :closed}

  # The largest frame read: twice the largest valid glass message, a
  # maximal intent of 65,840 bytes. The mount caps a single frame at the
  # same size, but the transport reassembles a fragmented message far past
  # it before this channel sees it.
  @max_frame_bytes 131_072

  # A verified glass is pinged this often, well inside the mount's
  # 90-second read timeout.
  @keepalive_ms 30_000

  # The intent that opens a declared stream, and the grants one connection
  # holds at most.
  @open_stream "streams.open"
  @max_grants 16

  # The mailbox depth past which the channel has fallen too far behind its
  # streams to deliver them faithfully.
  @max_backlog 1_000

  @typedoc """
  The channel's state:

    * `ctx` — the unauthenticated context `connect/1` built: this
      connection's request id and address, `origin: :interactive`.
    * `client` — the client's context once a proof verified, nil before.
    * `cert` — the certificate the verified client stands under, nil
      before.
    * `connect` — the body of the `connect` or `renew` the held challenge
      answers: `client_id` and the `certificate` that locates it.
    * `challenge` — the challenge held for this connection, nil when none
      is.
    * `deadline` — the token and timer of the deadline the proof must
      arrive before, nil when none is held or the channel closed.
    * `expiry` — the token and timer of the bound certificate's expiry.
    * `keepalive` — the token and timer of the next ping.
    * `call_id` — the call id the channel assigned the message it decided
      last.
    * `grants` — each stream open on this connection, by grant id: the
      grant, the stream's name, its forwarder and its deadline's timer.
    * `standing` — whether the channel hears the person's standing
      announcements.
    * `closed` — true once a refusal closed the channel: nothing after it
      is recorded or acted on.
  """
  @type state :: %{
          ctx: Context.t(),
          client: Context.t() | nil,
          cert: DeviceCert.t() | nil,
          connect: %{client_id: String.t(), certificate: DeviceCert.t()} | nil,
          challenge: Challenge.t() | nil,
          deadline: {reference(), reference()} | nil,
          expiry: {reference(), reference()} | nil,
          keepalive: {reference(), reference()} | nil,
          call_id: String.t() | nil,
          grants: %{
            optional(String.t()) => %{
              grant: StreamGrant.t(),
              stream: String.t(),
              forwarder: pid(),
              timer: {reference(), reference()}
            }
          },
          standing: boolean(),
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
       cert: nil,
       connect: nil,
       challenge: nil,
       deadline: nil,
       expiry: nil,
       keepalive: nil,
       call_id: nil,
       grants: %{},
       standing: false,
       closed: false
     }}
  end

  @impl true
  def init(state) do
    Prima.LoggerContext.set_request_id(state.ctx.request_id)
    {:ok, arm(state, Challenge.lifetime_ms())}
  end

  @impl true
  def handle_in(_frame, %{closed: true} = state), do: {:stop, @closed, state}

  def handle_in({frame, opts}, state) do
    state = %{state | call_id: Prima.UUID7.generate_id("call")}

    with :ok <- bounded(frame),
         :text <- Keyword.get(opts, :opcode),
         {:ok, map} <- Prima.Json.decode(frame),
         {:ok, message} <- Device.decode(map, :glass) do
      receive_message(message, state)
    else
      :oversize -> refuse(state, :oversize_frame)
      _malformed -> refuse(state, :malformed_frame)
    end
  end

  @impl true
  def handle_control(_frame, %{closed: true} = state), do: {:stop, @closed, state}
  def handle_control(_frame, state), do: {:ok, state}

  @impl true
  def handle_info(_message, %{closed: true} = state), do: {:stop, @closed, state}

  def handle_info(
        {__MODULE__, :deadline, token},
        %{deadline: {token, _timer}, client: nil} = state
      ),
      do: refuse(assign_call(state), :proof_missing)

  # A verified connection's renewal challenge ran out unanswered: the
  # client keeps the certificate it stands under, and the challenge is
  # dropped.
  def handle_info({__MODULE__, :deadline, token}, %{deadline: {token, _timer}} = state),
    do: {:ok, %{state | challenge: nil, connect: nil, deadline: nil}}

  def handle_info({__MODULE__, :expiry, token}, %{expiry: {token, _timer}} = state) do
    if now() >= state.cert.expires_at,
      do: refuse(assign_call(state), :certificate_expired),
      else: {:ok, arm_expiry(state)}
  end

  def handle_info({__MODULE__, :keepalive, token}, %{keepalive: {token, _timer}} = state) do
    case Sanctum.DeviceCerts.verify_request(state.cert, state.client, []) do
      {:ok, client} ->
        {:push, {:ping, ""}, keepalive(%{state | client: carried(client, state)})}

      # A store that cannot answer now decides nothing: the next request
      # reads it again, and the ping keeps the glass.
      {:error, :unavailable} ->
        {:push, {:ping, ""}, keepalive(state)}

      {:error, reason} ->
        refuse(assign_call(state), reason)
    end
  end

  # A grant's deadline: that stream ends; the channel stays.
  def handle_info({__MODULE__, {:grant, grant_id}, token}, state) do
    case Map.get(state.grants, grant_id) do
      %{timer: {^token, _timer}} ->
        {:push, revoke_frames(state, [grant_id]), drop_grants(state, [grant_id])}

      _stale ->
        {:ok, state}
    end
  end

  # A fact of a granted stream, delivered only to a client that keeps up
  # and still stands.
  def handle_info({__MODULE__, :fact, grant_id, message}, state) do
    case Map.get(state.grants, grant_id) do
      nil -> {:ok, state}
      granted -> deliver(granted, message, state)
    end
  end

  # A standing announcement about the person: the standing is read again
  # now, not at the next ping.
  def handle_info(message, %{client: %Context{} = client} = state)
      when is_struct(message, Session) or is_struct(message, Membership) or
             is_struct(message, AthanorArchived) do
    if about?(message, client), do: recheck(state), else: {:ok, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Before a proof verified: `connect` or `renew`, then `proof`, and
  # nothing else.
  # ---------------------------------------------------------------------------

  defp receive_message({:connect, body}, %{client: nil, connect: nil} = state),
    do: challenge(:connect, body, state)

  defp receive_message(
         {:renew, %{certificate: %DeviceCert{}} = body},
         %{client: nil, connect: nil} = state
       ),
       do: challenge(:renew, body, state)

  # A renewal that names no certificate names no athanor or device key to
  # challenge.
  defp receive_message({:renew, _body}, %{client: nil, connect: nil} = state),
    do: refuse(state, :unchallengeable)

  defp receive_message({:proof, %{proof: proof}}, %{client: nil} = state) do
    cond do
      is_nil(state.challenge) -> refuse(state, :proof_unchallenged)
      now() >= state.challenge.expires_at -> refuse(state, :proof_expired)
      true -> prove(proof, state)
    end
  end

  # An intent before a proof, a repeated confirmation among them, is
  # answered before the close, and its decision names the operation.
  defp receive_message({:intent, %{id: id, operation: operation}}, %{client: nil} = state) do
    refuse(state, :proof_missing,
      operation: operation,
      frames: [answer_refused(id, refusal(:proof_missing))]
    )
  end

  defp receive_message({:connect, _body}, state), do: refuse(state, :second_connect)

  defp receive_message({_type, _body}, %{client: nil} = state),
    do: refuse(state, :proof_missing)

  # Once a proof verified: each discrete intent, checked and then through
  # the gate, and the renewal exchange under the certificate the client
  # stands under.
  defp receive_message({:intent, intent}, state), do: admit(intent, state)

  defp receive_message({:renew, _body}, %{challenge: nil} = state),
    do: challenge(:renew, %{client_id: state.client.client_id, certificate: state.cert}, state)

  defp receive_message(
         {:proof, %{proof: proof}},
         %{challenge: %Challenge{purpose: :renew} = challenge} = state
       ) do
    if now() >= challenge.expires_at,
      do: refuse(state, :proof_expired),
      else: prove(proof, state)
  end

  defp receive_message({_type, _body}, state), do: refuse(state, :not_accepted)

  # The challenge for this connection's `connect` or `renew`: the home the
  # certificate names, which the verifier holds to this one, its athanor
  # and device key, the client id the glass named, and a nonce drawn here.
  # A renewal's certificate only locates the client: the verifier holds
  # the proof to the device key the client's row stores.
  defp challenge(purpose, %{client_id: client_id, certificate: certificate} = body, state) do
    case Challenge.new(
           purpose: purpose,
           home: certificate.audience,
           athanor: certificate.athanor,
           client_id: client_id,
           device_key: certificate.device_key,
           nonce: :crypto.strong_rand_bytes(Challenge.nonce_bytes()),
           now: now()
         ) do
      {:ok, challenge} ->
        state = arm(%{state | connect: body, challenge: challenge}, challenge.expires_at - now())
        {:reply, :ok, {:text, wire({:challenge, %{challenge: challenge}})}, state}

      {:error, _unchallengeable} ->
        refuse(state, :unchallengeable)
    end
  end

  # A proof goes to the verifier with the message and the challenge held
  # for it; the challenge is answered once, whatever the verdict.
  defp prove(proof, %{challenge: %Challenge{purpose: purpose} = challenge} = state) do
    connection = Map.put(state.connect, :source, state.ctx.client_ip)

    case Sanctum.DeviceCerts.verify_connect(connection, proof, challenge) do
      {:ok, client} when purpose == :connect ->
        verified(state, client, state.connect.certificate, [])

      {:ok, client} ->
        renew(proof, client, %{state | challenge: nil})

      {:error, reason} ->
        refuse(state, reason)
    end
  end

  # The one operation a renewal's context is used for: `pairing/renew`,
  # through the gate, with the device key the proof was made by. The
  # replacement is checked as every request's certificate is before the
  # client stands under it.
  defp renew(proof, client, state) do
    ctx = %{
      carried(client, state)
      | call_id: state.call_id,
        confirmation_id: nil,
        origin: :interactive
    }

    args = %{
      "action" => "renew",
      "client_id" => ctx.client_id,
      "device_key" => Encoding.b64(proof.challenge.device_key),
      "proof" => Proof.encode(proof)
    }

    case Grimoire.call_external("pairing", ctx, args,
           call_id: state.call_id,
           method: "device/renew"
         ) do
      {:ok, %{certificate: issued}} ->
        with {:ok, certificate} <- DeviceCert.decode(issued),
             {:ok, client} <- Sanctum.DeviceCerts.verify_request(certificate, ctx, []) do
          verified(state, client, certificate, [{:certificate, %{certificate: certificate}}])
        else
          # The gate decided the renewal under its call id; the refusal of
          # its replacement is a decision of its own.
          {:error, reason} -> refuse(assign_call(state), reason)
        end

      {:error, reason} ->
        refuse(state, :renewal_refused, refusal: renewal_refusal(reason), record: false)
    end
  end

  # A client that proved its key: its context, the certificate it stands
  # under, no challenge or proof deadline, its expiry and its keepalive
  # armed, and `standing` answered after anything the caller sends first.
  defp verified(state, client, certificate, frames) do
    cancel(state.deadline)

    state =
      %{
        state
        | client: carried(client, state),
          cert: certificate,
          connect: nil,
          challenge: nil,
          deadline: nil
      }
      |> arm_expiry()
      |> keepalive()

    standing =
      {:standing,
       %{
         client_id: state.client.client_id,
         athanor: state.client.athanor_id,
         expires_at: certificate.expires_at
       }}

    {:push, Enum.map(frames ++ [standing], &{:text, wire(&1)}), state}
  end

  # What this connection brings to the client's context: its request
  # correlation and its address.
  defp carried(%Context{} = client, state),
    do: %{client | request_id: state.ctx.request_id, client_ip: state.ctx.client_ip}

  # An intent is dispatched only under a certificate and a standing read
  # now; a client whose certificate or standing no longer holds is
  # answered, then closed.
  defp admit(%{id: id, operation: operation} = intent, state) do
    case Sanctum.DeviceCerts.verify_request(state.cert, state.client, []) do
      {:ok, client} ->
        dispatch(intent, %{state | client: carried(client, state)})

      {:error, reason} ->
        refusal = refusal(reason)

        refuse(state, reason,
          refusal: refusal,
          operation: operation,
          frames: [answer_refused(id, refusal)]
        )
    end
  end

  defp dispatch(%{operation: @open_stream} = intent, state), do: open_stream(intent, state)

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

  # ---------------------------------------------------------------------------
  # Streams
  # ---------------------------------------------------------------------------

  # `streams.open`: the stream and subject read as a frame's open reads
  # them, the connection's bound, then the gate's stream admission. A
  # refusal here, before the gate, is recorded as one; the gate records
  # its own.
  defp open_stream(%{id: id, args: args}, state) do
    ctx = %{
      state.client
      | request_id: state.ctx.request_id,
        call_id: state.call_id,
        confirmation_id: nil,
        origin: :interactive
    }

    with {:ok, name, subject} <- stream_args(args),
         :ok <- grant_room(state) do
      case Grimoire.open_stream(ctx, name, subject) do
        {:ok, grant} ->
          granted(id, name, grant, state)

        {:error, refusal} ->
          {:reply, :ok, {:text, wire({:answer, %{id: id, error: error(refusal)}})}, state}
      end
    else
      {:error, reason} ->
        refusal = %{Grimoire.classify(reason) | stage: :admission}
        record(state, refusal, "streams", "open")
        {:reply, :ok, answer_refused(id, refusal), state}
    end
  end

  defp stream_args(args) do
    stream = Map.get(args, "stream")
    subject = Map.get(args, "subject")

    cond do
      Map.keys(args) -- ["stream", "subject"] != [] ->
        {:error, {:invalid_argument, "streams.open takes a stream and, for some, a subject"}}

      not Prima.Manifest.Tincture.stream_name?(stream) ->
        {:error, {:invalid_argument, "streams.open needs the name of a declared stream"}}

      not (is_nil(subject) or Prima.Manifest.Tincture.literal_subject?(subject)) ->
        {:error, {:invalid_argument, "The subject must be a literal subject or absent"}}

      true ->
        {:ok, stream, subject}
    end
  end

  defp grant_room(%{grants: grants}) when map_size(grants) < @max_grants, do: :ok
  defp grant_room(_state), do: {:error, :stream_limit}

  # An admitted open: its forwarder subscribed to the one topic the grant
  # admits before the grant is answered, its deadline armed, and the
  # person's standing announcements heard.
  defp granted(id, name, grant, state) do
    actor = Context.actor(state.client)
    topic = Cyfr.Bus.granted_topic(actor, grant)

    case Forwarder.start(self(), grant.grant_id, actor, topic, payload_struct(grant)) do
      {:ok, forwarder} -> deliver_grant(id, name, grant, forwarder, state)
      {:error, _unstarted} -> undeliverable(id, grant, state)
    end
  end

  # An admitted open no forwarder could hear: the client is told, and the
  # grant it was admitted for is revoked at once, so nothing waits on it.
  defp undeliverable(id, grant, state) do
    error = %{
      "class" => "unavailable",
      "message" => "This home could not deliver the stream now; open it again shortly"
    }

    frames = [
      {:answer, %{id: id, error: error}},
      {:revoke, %{client_id: state.client.client_id, grant_id: grant.grant_id}}
    ]

    {:push, Enum.map(frames, &{:text, wire(&1)}), state}
  end

  defp deliver_grant(id, name, grant, forwarder, state) do
    timer =
      timer(
        nil,
        {:grant, grant.grant_id},
        DateTime.diff(grant.deadline, DateTime.utc_now(), :millisecond)
      )

    state =
      state
      |> put_in([:grants, grant.grant_id], %{
        grant: grant,
        stream: name,
        forwarder: forwarder,
        timer: timer
      })
      |> hear_standing()

    body =
      %{
        grant_id: grant.grant_id,
        stream: name,
        projection: grant.projection,
        expires_at: DateTime.to_unix(grant.deadline, :millisecond)
      }
      |> then(fn body ->
        if grant.subject, do: Map.put(body, :subject, grant.subject), else: body
      end)

    frames = [
      {:answer, %{id: id, result: %{"grant_id" => grant.grant_id}}},
      {:grant, body}
    ]

    {:push, Enum.map(frames, &{:text, wire(&1)}), state}
  end

  # The one struct the grant's topic carries (the bus roster's).
  defp payload_struct(%StreamGrant{topic: key}),
    do: Enum.find_value(Cyfr.Bus.topics(), fn row -> row.key == key && row.struct end)

  defp hear_standing(%{standing: true} = state), do: state

  defp hear_standing(state) do
    :ok = Cyfr.Bus.subscribe_standing(state.client.user_id)
    %{state | standing: true}
  end

  defp deliver(%{grant: grant}, message, state) do
    cond do
      overflowing?() ->
        grant_ids = Map.keys(state.grants)
        {:push, revoke_frames(state, grant_ids), drop_grants(state, grant_ids)}

      Sanctum.Caller.fresh?(state.client) ->
        {:push, event(grant, message), state}

      true ->
        case Sanctum.DeviceCerts.verify_request(state.cert, state.client, []) do
          {:ok, client} ->
            {:push, event(grant, message), %{state | client: carried(client, state)}}

          # A store that cannot answer now cannot vouch for the client: the
          # fact is not delivered, and its stream ends, as on overflow, so
          # the client opens it again rather than miss a fact unawares.
          {:error, :unavailable} ->
            {:push, revoke_frames(state, [grant.grant_id]), drop_grants(state, [grant.grant_id])}

          {:error, reason} ->
            refuse(assign_call(state), reason)
        end
    end
  end

  defp event(grant, %{} = message) do
    payload = StreamGrant.project(grant, Map.from_struct(message))
    {:text, wire({:event, %{grant_id: grant.grant_id, payload: payload}})}
  end

  defp overflowing? do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, depth} -> depth > @max_backlog
      nil -> false
    end
  end

  defp recheck(state) do
    case Sanctum.DeviceCerts.verify_request(state.cert, state.client, []) do
      {:ok, client} -> {:ok, %{state | client: carried(client, state)}}
      {:error, :unavailable} -> {:ok, state}
      {:error, reason} -> refuse(assign_call(state), reason)
    end
  end

  # Which standing announcements are about this client's person.
  defp about?(%Session{kind: kind, user_id: user_id}, ctx),
    do: kind != :created and user_id == ctx.user_id

  defp about?(%AthanorArchived{athanor_id: athanor_id}, ctx), do: athanor_id == ctx.athanor_id
  defp about?(%Membership{}, _ctx), do: true

  # `revoke` for each of `grant_ids`, naming the client.
  defp revoke_frames(state, grant_ids) do
    for grant_id <- grant_ids,
        do: {:text, wire({:revoke, %{client_id: state.client.client_id, grant_id: grant_id}})}
  end

  defp drop_grants(state, grant_ids) do
    for grant_id <- grant_ids,
        %{forwarder: forwarder, timer: timer} <- [state.grants[grant_id]] do
      cancel(timer)
      Forwarder.stop(forwarder)
    end

    %{state | grants: Map.drop(state.grants, grant_ids)}
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
  # state is closed for good first, every timer cancelled, so a frame or
  # a timer the transport still delivers before the peer's close records
  # nothing. `record: false` closes a refusal the gate already recorded.
  defp refuse(state, reason, opts \\ []) do
    for timer <- [state.deadline, state.expiry, state.keepalive], do: cancel(timer)
    refusal = Keyword.get_lazy(opts, :refusal, fn -> refusal(reason) end)
    code = close_code(refusal)
    # Each stream ends with the connection, and a client whose standing
    # ended is told its pairing ended too.
    revokes = revoke_frames_on_close(state, code)
    state = drop_grants(state, Map.keys(state.grants))
    state = %{state | deadline: nil, expiry: nil, keepalive: nil, closed: true}

    if Keyword.get(opts, :record, true) do
      {tool, action} = names(Keyword.get(opts, :operation))
      record(state, refusal, tool, action)
    end

    close(state, code, close_reason(refusal), Keyword.get(opts, :frames, []) ++ revokes)
  end

  defp revoke_frames_on_close(%{client: %Context{client_id: client_id}} = state, code) do
    pairing =
      if code == @standing_ended,
        do: [{:text, wire({:revoke, %{client_id: client_id}})}],
        else: []

    revoke_frames(state, Map.keys(state.grants)) ++ pairing
  end

  defp revoke_frames_on_close(_state, _code), do: []

  # One refused decision under the call id assigned the refused message.
  defp record(state, refusal, tool, action) do
    decision =
      Grimoire.refused_decision(state.client, refusal,
        call_id: state.call_id,
        request_id: state.ctx.request_id,
        plane: :external,
        tool: tool,
        action: action
      )

    Grimoire.open_decision(state.client, decision, %{method: "device", input: %{}})
  end

  defp close(state, code, reason, []), do: {:stop, :normal, {code, reason}, state}
  defp close(state, code, reason, frames), do: {:stop, :normal, {code, reason}, frames, state}

  # The close reason is the refusal's class; a spent bound adds when to
  # try again, in whole seconds.
  defp close_reason(%Prima.Refusal{reason: {:rate_limited, retry_after_ms}} = refusal),
    do: "#{refusal.class}; retry_after_s=#{retry_after_s(retry_after_ms)}"

  defp close_reason(%Prima.Refusal{class: class}), do: Atom.to_string(class)

  defp retry_after_s(ms), do: max(div(ms + 999, 1_000), 1)

  defp close_code(%Prima.Refusal{reason: reason})
       when reason in [:oversize_frame, :malformed_frame],
       do: @malformed

  defp close_code(%Prima.Refusal{reason: reason})
       when reason in [:expired, :certificate_expired, :bad_signature],
       do: @renew

  defp close_code(%Prima.Refusal{class: :forbidden}), do: @standing_ended

  defp close_code(%Prima.Refusal{class: class})
       when class in [:unavailable, :rate_limited, :not_owner],
       do: @try_again

  defp close_code(%Prima.Refusal{}), do: @unproven

  defp answer_refused(id, %Prima.Refusal{} = refusal) do
    error = %{"class" => Atom.to_string(refusal.class), "message" => refusal.message}
    {:text, wire({:answer, %{id: id, error: error}})}
  end

  # A renewal the gate refused, in the class and sentence the gate gave
  # it, so its close says what ended it.
  defp renewal_refusal(reason) do
    refusal = Grimoire.classify(reason)
    %{refusal | reason: :renewal_refused, stage: :admission}
  end

  defp refusal(reason) do
    %Prima.Refusal{
      class: class(reason),
      reason: reason,
      message: sentence(reason),
      stage: :admission
    }
  end

  defp class(reason) when reason in [:revoked, :not_standing], do: :forbidden
  defp class(:unavailable), do: :unavailable
  defp class({:rate_limited, _retry_after_ms}), do: :rate_limited
  defp class(_reason), do: :unauthenticated

  defp sentence(:oversize_frame), do: "The frame is larger than any device protocol message"
  defp sentence(:malformed_frame), do: "The frame is not a device protocol message a glass sends"
  defp sentence(:proof_missing), do: "The device has not proven its key on this connection"
  defp sentence(:proof_unchallenged), do: "The proof answers no challenge this connection holds"
  defp sentence(:proof_expired), do: "The proof arrived after its challenge expired"
  defp sentence(:proof_refused), do: "The device's proof of its key was refused"
  defp sentence(:second_connect), do: "This connection has already presented its certificate"
  defp sentence(:unchallengeable), do: "This home cannot challenge the device's certificate"
  defp sentence(:not_accepted), do: "This connection does not take that message"

  defp sentence(reason) when reason in [:expired, :certificate_expired],
    do: "The device's certificate has expired; renew it"

  defp sentence(:bad_signature),
    do: "The device's certificate is not signed by its person's current key; renew it"

  defp sentence(:not_yet_valid), do: "The device's certificate is not valid yet"
  defp sentence(:wrong_audience), do: "The device's certificate is for another home"
  defp sentence(:unknown_subject), do: "The device's certificate names no person of this home"

  defp sentence(:client_mismatch),
    do: "The device's certificate names another client than this connection's"

  defp sentence(:remote_identity_unavailable),
    do: "A device of a person whose identity is at another home cannot connect here yet"

  defp sentence(:revoked), do: "This device's pairing was revoked"

  defp sentence(:not_standing),
    do: "The person behind this device no longer stands in this athanor"

  defp sentence(:unavailable), do: "This home could not check the device now; retry shortly"

  defp sentence({:rate_limited, retry_after_ms}),
    do: "Too many device verifications from here; retry in #{retry_after_s(retry_after_ms)} s"

  defp sentence(_reason), do: "The device's certificate could not be renewed"

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

  # A timer message decided on its own, not on a frame: its own call id.
  defp assign_call(state), do: %{state | call_id: Prima.UUID7.generate_id("call")}

  # The proof must arrive within `ms`: a timer whose token the state
  # holds, replacing the one before, so a stale timer decides nothing.
  defp arm(state, ms), do: %{state | deadline: timer(state.deadline, :deadline, ms)}

  # The bound certificate's expiry, on this home's clock.
  defp arm_expiry(state),
    do: %{state | expiry: timer(state.expiry, :expiry, state.cert.expires_at - now())}

  defp keepalive(state),
    do: %{state | keepalive: timer(state.keepalive, :keepalive, @keepalive_ms)}

  defp timer(previous, kind, ms) do
    cancel(previous)
    token = make_ref()
    {token, Process.send_after(self(), {__MODULE__, kind, token}, max(ms, 0))}
  end

  defp cancel({_token, timer}), do: Process.cancel_timer(timer)
  defp cancel(nil), do: false

  defp wire(message), do: message |> Device.encode() |> Jason.encode!()

  defp now, do: System.system_time(:millisecond)
end

defmodule Emissary.Web.DeviceChannel.Forwarder do
  @moduledoc false
  # One granted stream of a device channel: subscribed to the one topic
  # its grant admits, it hands each fact of the grant's payload struct to
  # the channel under the grant's id, so a channel holding several grants
  # knows which a fact belongs to. It ends with the channel, or when the
  # channel ends the grant. It reaches no store.

  @ready_ms 5_000

  @doc false
  # Started subscribed: the grant is answered only once its topic is heard.
  # A forwarder that could not start, could not subscribe or did not say so
  # in time is `{:error, reason}`, and none is left running.
  @spec start(pid(), String.t(), Prima.Actor.t(), String.t(), module()) ::
          {:ok, pid()} | {:error, term()}
  def start(channel, grant_id, actor, topic, payload) do
    ready = make_ref()

    case start_child(fn -> run(channel, ready, grant_id, actor, topic, payload) end) do
      {:ok, pid} ->
        receive do
          {^ready, :subscribed} ->
            {:ok, pid}

          {^ready, {:error, reason}} ->
            {:error, reason}
        after
          @ready_ms ->
            Task.Supervisor.terminate_child(Emissary.Web.TaskSupervisor, pid)
            {:error, :not_subscribed}
        end

      {:error, reason} ->
        {:error, reason}

      _not_started ->
        {:error, :not_started}
    end
  end

  # The supervisor itself may be gone, or restarting.
  defp start_child(fun) do
    Task.Supervisor.start_child(Emissary.Web.TaskSupervisor, fun)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc false
  @spec stop(pid()) :: :ok
  def stop(pid) do
    send(pid, {__MODULE__, :stop})
    :ok
  end

  defp run(channel, ready, grant_id, actor, topic, payload) do
    monitor = Process.monitor(channel)

    case Cyfr.Bus.subscribe(actor, topic) do
      :ok ->
        send(channel, {ready, :subscribed})
        loop(channel, monitor, grant_id, payload)

      {:error, reason} ->
        send(channel, {ready, {:error, reason}})
    end
  end

  defp loop(channel, monitor, grant_id, payload) do
    receive do
      {:DOWN, ^monitor, :process, _pid, _reason} ->
        :ok

      {__MODULE__, :stop} ->
        :ok

      %{__struct__: ^payload} = message ->
        send(channel, {Emissary.Web.DeviceChannel, :fact, grant_id, message})
        loop(channel, monitor, grant_id, payload)

      _other ->
        loop(channel, monitor, grant_id, payload)
    end
  end
end
