# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.DeviceChannelTest do
  @moduledoc """
  The device channel.

  The upgrade admits nothing and holds an unauthenticated context whose
  origin is `interactive` whatever the query says. `connect` is answered
  with a `connect` challenge bound to this home, the certificate and the
  client, and a proof goes to `Sanctum.DeviceCerts.verify_connect/3`: a
  verified one sets the client's context (`:device`, its client id),
  clears the challenge and its deadline and answers `standing`; each
  intent after it is checked against the certificate and the client's
  standing, read anew, then dispatched through the gate under that
  context. A glass renews through the fixed renewal exchange, under the
  key its paired-client row stores, and the replacement is checked before
  anything else is admitted. After a proof the channel pings every 30
  seconds, reads the standing again at each ping, and closes when its
  certificate expires unrenewed.

  A refused connection is one decision, counted by the connection's
  request id, under the call id the channel assigned the refused message,
  with its refusal class, no request-log row of the transport's, and the
  socket closes `4400` for a frame the protocol refuses by its shape or
  size, `4401` for a connection that has not proven its key, `4403` for a
  client whose standing ended and `4408` for a certificate to renew, the
  class as the close reason. The refusal closes the channel for good:
  anything the transport delivers after it records nothing and stops the
  connection. A failed connect proof counts against the bound pairing
  completions are held to.

  Every paired device here comes from the real ceremony
  (`Sanctum.Pairing`). No WebSocket client is in the dependencies, so the
  transport callbacks are driven directly, as the transport drives them
  (`connect/1`, `init/1`, `handle_in/2`, `handle_info/2`,
  `handle_control/2`), and timers the channel arms arrive in the test
  process that drove it. The endpoint's mount is read through
  `CyfrWeb.Endpoint.__sockets__/0`, the upgrade is driven through the
  endpoint on the test adapter, and one case speaks the WebSocket protocol
  over a socket to a real listener, to show a refused connection's process
  ends.
  """

  # The rate limiter's table and the settings' cache are the node's.
  use CyfrWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.PersonIdentity
  alias Emissary.Web.DeviceChannel
  alias Prima.{Device, DeviceCert}
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  @vectors Path.expand("../../../../../tests/fixtures/device.json", __DIR__)
  @external_resource @vectors

  setup do
    Prima.RateLimiter.reset()
    on_exit(fn -> Prima.RateLimiter.reset() end)
    {:ok, glass: glass()}
  end

  # ==========================================================================
  # The mount and the upgrade
  # ==========================================================================

  describe "the mount" do
    test "the endpoint mounts the channel at /device, a WebSocket carrying the address and no session" do
      assert [{"/device", DeviceChannel, opts}] =
               Enum.filter(CyfrWeb.Endpoint.__sockets__(), &match?({"/device", _, _}, &1))

      assert opts[:websocket][:connect_info] == [:peer_data, :x_headers]
      assert opts[:longpoll] == false
    end

    test "the mount caps a frame, and its idle timeout sits above the proof deadline and the ping" do
      {"/device", DeviceChannel, opts} =
        Enum.find(CyfrWeb.Endpoint.__sockets__(), &match?({"/device", _, _}, &1))

      assert opts[:websocket][:max_frame_size] == 131_072
      assert opts[:websocket][:timeout] == 90_000
      assert opts[:websocket][:timeout] > Challenge.lifetime_ms()
      assert opts[:websocket][:timeout] > 30_000
    end

    test "the upgrade admits nothing and holds an interactive context, whatever the query says",
         %{conn: conn} do
      # The upgrade's own check reads a `host` header, which the test
      # adapter carries only as the conn's field.
      conn =
        %{conn | req_headers: [{"host", conn.host} | conn.req_headers]}
        |> put_req_header("connection", "upgrade")
        |> put_req_header("upgrade", "websocket")
        |> put_req_header("sec-websocket-key", Base.encode64(:crypto.strong_rand_bytes(16)))
        |> put_req_header("sec-websocket-version", "13")
        |> put_req_header("cookie", "_cyfr_key=not-a-session")
        |> Phoenix.ConnTest.dispatch(
          CyfrWeb.Endpoint,
          :get,
          "/device/websocket?origin=programmatic&client_id=pcl_query"
        )

      assert conn.state == :upgraded
      {_adapter, %{ref: ref}} = conn.adapter
      assert_received {^ref, :upgrade, {:websocket, {DeviceChannel, state, _opts}}}

      assert state.ctx.origin == :interactive
      assert state.ctx.authenticated == false
      assert is_nil(state.ctx.user_id) and is_nil(state.ctx.athanor_id)
      assert is_nil(state.ctx.client_id) and is_nil(state.ctx.session_token_hash)
      assert "req_" <> _ = state.ctx.request_id
      assert is_nil(state.client) and is_nil(state.connect) and is_nil(state.challenge)
    end
  end

  # ==========================================================================
  # The context
  # ==========================================================================

  describe "the context" do
    test "connect/1 holds an unauthenticated interactive context and reads no origin from the query" do
      {:ok, state} = DeviceChannel.connect(transport_info(%{"origin" => "programmatic"}))
      {:ok, state} = DeviceChannel.init(state)

      assert %Sanctum.Context{origin: :interactive, authenticated: false, plane: :external} =
               state.ctx

      assert state.ctx.client_ip == "127.0.0.1"
    end

    test "the context stays interactive through connect", %{glass: glass} do
      {:ok, state} = DeviceChannel.connect(transport_info(%{"origin" => "webhook"}))
      {:ok, state} = DeviceChannel.init(state)

      assert {:reply, :ok, {:text, _challenge}, state} =
               send_frame(state, connect_message(glass))

      assert state.ctx.origin == :interactive
    end

    test "a message carrying an origin is refused by its shape", %{glass: glass} do
      state = channel()
      message = Map.put(connect_message(glass), "origin", "programmatic")
      assert_refused(send_frame(state, message), 4400)
    end
  end

  # ==========================================================================
  # The sequence
  # ==========================================================================

  describe "connect and proof" do
    test "connect is answered with a connect challenge bound to this home, the certificate and the client",
         %{glass: glass} do
      state = channel()
      before = System.system_time(:millisecond)

      assert {:reply, :ok, {:text, json}, state} = send_frame(state, connect_message(glass))

      assert {:ok, {:challenge, %{challenge: %Challenge{} = challenge}}} =
               Device.decode(Jason.decode!(json), :home)

      assert challenge.purpose == :connect
      # This home as certificates name it.
      assert challenge.home == Sanctum.Person.home()
      assert challenge.athanor == glass.cert.athanor
      assert challenge.client_id == glass.client_id
      assert challenge.device_key == glass.cert.device_key
      assert byte_size(challenge.nonce) == Challenge.nonce_bytes()
      assert challenge.expires_at >= before + Challenge.lifetime_ms()
      assert state.challenge == challenge
      assert state.connect == %{client_id: glass.client_id, certificate: glass.cert}

      # The connect is no admission: it records nothing.
      assert decisions_of(state.ctx.request_id) == []
      refute state.closed
    end

    test "each connection draws its own nonce", %{glass: glass} do
      {_state, first} = connected(glass)
      {_state, second} = connected(glass)
      refute first.nonce == second.nonce
    end

    test "a proof for a certificate no person of this home signed is refused", %{glass: glass} do
      {state, challenge} = connected(glass)
      state = assert_refused(send_frame(state, proof_message(challenge, glass)), 4401)
      assert is_nil(state.client)
    end
  end

  describe "a verified proof" do
    setup [:seated]

    test "sets the client, clears the challenge, cancels the deadline and answers standing", %{
      session_ctx: session_ctx,
      user: user,
      athanor: athanor
    } do
      device = pair!(session_ctx)
      {state, challenge} = connected(device)
      {_token, deadline_timer} = state.deadline

      assert {:push, [{:text, json}], state} = send_frame(state, proof_message(challenge, device))

      assert {:ok, {:standing, standing}} = Device.decode(Jason.decode!(json), :home)

      assert standing == %{
               client_id: device.client_id,
               athanor: athanor.id,
               expires_at: device.cert.expires_at
             }

      assert %Context{auth_method: :device, origin: :interactive} = state.client
      assert state.client.client_id == device.client_id
      assert {state.client.user_id, state.client.athanor_id} == {user.id, athanor.id}
      assert state.client.request_id == state.ctx.request_id
      assert state.cert == device.cert
      assert is_nil(state.challenge) and is_nil(state.deadline)
      assert Process.read_timer(deadline_timer) == false
      assert {_token, _timer} = state.expiry
      assert {_token, _timer} = state.keepalive
      refute state.closed

      # A proven connection is no admission: nothing is recorded for it.
      assert decisions_of(state.ctx.request_id) == []
    end

    test "each intent is dispatched through the gate under the client's context", %{
      session_ctx: session_ctx,
      user: user,
      athanor: athanor
    } do
      device = pair!(session_ctx)
      state = proven(device)

      assert {:reply, :ok, {:text, json}, state} =
               send_frame(state, intent_message("int_1", "pairing.list", %{}))

      assert {:ok, {:answer, %{id: "int_1", result: %{"clients" => [client]}}}} =
               json |> Jason.decode!() |> Device.decode(:home)

      # The gate saw the client itself: the one it lists as the caller's.
      assert client["client_id"] == device.client_id
      assert client["current"] == true

      assert [decision] = decisions_of(state.ctx.request_id)
      assert decision.call_id == state.call_id
      assert {decision.tool, decision.action} == {"pairing", "list"}
      assert decision.admission == "admitted"
      assert {decision.user_id, decision.athanor_id} == {user.id, athanor.id}
    end

    test "a proof under a key the certificate does not name is closed", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      {state, challenge} = connected(device)
      {_other, other_private} = :crypto.generate_key(:eddsa, :ed25519)

      assert_refused(
        send_frame(
          state,
          Device.encode({:proof, %{proof: Proof.sign(challenge, other_private)}})
        ),
        4401
      )
    end
  end

  # ==========================================================================
  # 4403: the client's standing ended
  # ==========================================================================

  describe "4403" do
    setup [:seated]

    test "a revoked client's intent is answered and closed, before any dispatch", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      state = proven(device)
      {:ok, _row} = Sanctum.Pairing.revoke(session_ctx, device.client_id)

      {answer, decision} =
        assert_refused_answering(
          send_frame(state, intent_message("int_1", "pairing.list", %{})),
          4403,
          "forbidden"
        )

      assert {:ok, {:answer, %{id: "int_1", error: %{"class" => "forbidden"}}}} =
               Device.decode(answer, :home)

      # Under the client's identity, naming the operation, never dispatched.
      assert {decision.tool, decision.action} == {"pairing", "list"}
      assert decision.user_id == device.cert.subject.user_id
    end

    test "a revoked client's idle channel closes at its next ping", %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      state = proven(device)
      {token, _timer} = state.keepalive
      {:ok, _row} = Sanctum.Pairing.revoke(session_ctx, device.client_id)

      assert_refused(
        DeviceChannel.handle_info({DeviceChannel, :keepalive, token}, state),
        4403,
        "forbidden",
        :established
      )
    end

    test "a person who left the athanor is refused before new work", %{
      session_ctx: session_ctx,
      user: user,
      athanor: athanor
    } do
      device = pair!(session_ctx)
      state = proven(device)

      # A second member keeps the group open while the person leaves.
      other = seated(%{})
      {:ok, _} = Members.ensure(other.user.id, scope: "athanor", athanor_id: athanor.id)
      :ok = Members.remove_member(athanor, user_id: user.id)

      assert_refused_answering(
        send_frame(state, intent_message("int_1", "pairing.list", %{})),
        4403,
        "forbidden"
      )
    end

    test "a revoked client cannot renew", %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      {:ok, _row} = Sanctum.Pairing.revoke(session_ctx, device.client_id)
      {state, challenge} = renewing(device)

      assert_refused(send_frame(state, proof_message(challenge, device)), 4403, "forbidden")
    end
  end

  # ==========================================================================
  # 4408: the certificate to renew
  # ==========================================================================

  describe "4408" do
    setup [:seated]

    test "a certificate expiring during an open channel closes it at expiry", %{
      session_ctx: session_ctx
    } do
      Sanctum.Test.Settings.put("device_cert_seconds", 1)
      device = pair!(session_ctx)
      state = proven(device)
      {token, _timer} = state.expiry

      # The timer the channel armed arrives at the certificate's expiry.
      assert_receive {DeviceChannel, :expiry, ^token}, 3_000
      assert System.system_time(:millisecond) >= device.cert.expires_at

      assert_refused(
        DeviceChannel.handle_info({DeviceChannel, :expiry, token}, state),
        4408,
        "unauthenticated",
        :established
      )
    end

    test "a certificate presented at or after its expiry is refused, and an intent after it", %{
      session_ctx: session_ctx
    } do
      Sanctum.Test.Settings.put("device_cert_seconds", 1)
      device = pair!(session_ctx)
      state = proven(device)
      past_expiry(device.cert)

      # An intent on the open channel.
      assert_refused_answering(
        send_frame(state, intent_message("int_1", "pairing.list", %{})),
        4408,
        "unauthenticated"
      )

      # A new connection under it.
      {state, challenge} = connected(device)
      assert_refused(send_frame(state, proof_message(challenge, device)), 4408)
    end

    test "a certificate chained to a key the person's row no longer names is refused", %{
      session_ctx: session_ctx,
      user: user
    } do
      device = pair!(session_ctx)
      rotate_live_key!(user.id)
      {state, challenge} = connected(device)

      assert_refused(send_frame(state, proof_message(challenge, device)), 4408)
    end
  end

  # ==========================================================================
  # Renewal
  # ==========================================================================

  describe "renewal" do
    setup [:seated]

    test "on reconnect, the stored key renews and the replacement is checked before any intent",
         %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      {state, challenge} = renewing(device)

      assert challenge.purpose == :renew
      assert challenge.device_key == device.cert.device_key

      assert {:push, [{:text, certificate_json}, {:text, standing_json}], state} =
               send_frame(state, proof_message(challenge, device))

      assert {:ok, {:certificate, %{certificate: renewed}}} =
               Device.decode(Jason.decode!(certificate_json), :home)

      assert {:ok, {:standing, %{expires_at: expires_at}}} =
               Device.decode(Jason.decode!(standing_json), :home)

      assert renewed.client_id == device.client_id
      assert renewed.device_key == device.cert.device_key
      assert expires_at == renewed.expires_at
      assert state.cert == renewed
      assert %Context{auth_method: :device} = state.client
      assert {:ok, _ctx} = Sanctum.DeviceCerts.verify_request(renewed, state.client, [])

      # The gate decided the one renewal operation, under the client.
      assert [decision] = decisions_of(state.ctx.request_id)

      assert {decision.tool, decision.action, decision.admission} ==
               {"pairing", "renew", "admitted"}

      # Intents are admitted under the replacement.
      assert {:reply, :ok, {:text, _json}, _state} =
               send_frame(state, intent_message("int_1", "pairing.list", %{}))
    end

    test "after the live key rotated, reconnecting renews under the new key", %{
      session_ctx: session_ctx,
      user: user
    } do
      device = pair!(session_ctx)
      new_key = rotate_live_key!(user.id)
      {state, challenge} = renewing(device)

      assert {:push, [{:text, certificate_json}, _standing], _state} =
               send_frame(state, proof_message(challenge, device))

      {:ok, {:certificate, %{certificate: renewed}}} =
        Device.decode(Jason.decode!(certificate_json), :home)

      assert {:ok, _} =
               DeviceCert.verify(renewed, new_key,
                 home: Sanctum.Person.home(),
                 now: System.system_time(:millisecond),
                 skew: 0
               )
    end

    test "on a verified channel the glass renews under the certificate it stands under", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      state = proven(device)
      {expiry_token, _timer} = state.expiry

      assert {:reply, :ok, {:text, json}, state} =
               send_frame(state, Device.encode({:renew, %{client_id: device.client_id}}))

      {:ok, {:challenge, %{challenge: challenge}}} = Device.decode(Jason.decode!(json), :home)
      assert challenge.purpose == :renew

      assert {:push, [{:text, _certificate}, {:text, _standing}], renewed} =
               send_frame(state, proof_message(challenge, device))

      refute renewed.cert == device.cert
      refute match?({^expiry_token, _}, renewed.expiry)

      # The proof is answered once: replayed, it finds no challenge held.
      assert_refused(
        send_frame(renewed, proof_message(challenge, device)),
        4401,
        "unauthenticated",
        :established
      )
    end

    test "a replacement that fails its check records its refusal, then closes", %{
      session_ctx: session_ctx
    } do
      # A replacement lives a second, and its issuance is held past that
      # before the channel checks it: the check finds it expired.
      Sanctum.Test.Settings.put("device_cert_seconds", 1)
      device = pair!(session_ctx)
      {state, challenge} = renewing(device)
      me = self()
      handler = "device-channel-test-hold-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          &__MODULE__.hold_certificate_insert/4,
          me
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      result = send_frame(state, proof_message(challenge, device))
      :telemetry.detach(handler)

      closed = assert_refused(result, 4408)

      # Two decisions for the connection: the gate's admitted renewal, and
      # the refusal of what it issued, under a call id of its own.
      decisions = decisions_of(closed.ctx.request_id)
      assert [renewal] = Enum.filter(decisions, &(&1.admission == "admitted"))
      assert {renewal.tool, renewal.action} == {"pairing", "renew"}
      refute renewal.call_id == closed.call_id
    end

    test "an ordinary intent naming pairing.renew is refused and issues nothing", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      state = proven(device)

      {:ok, challenge} =
        Challenge.new(
          purpose: :renew,
          home: device.cert.audience,
          athanor: device.cert.athanor,
          client_id: device.client_id,
          device_key: device.cert.device_key,
          nonce: :crypto.strong_rand_bytes(Challenge.nonce_bytes()),
          now: System.system_time(:millisecond)
        )

      intent =
        intent_message("int_renew", "pairing.renew", %{
          "client_id" => device.client_id,
          "device_key" => Base.url_encode64(device.cert.device_key, padding: false),
          "proof" => Proof.encode(Proof.sign(challenge, device.private))
        })

      assert {:reply, :ok, {:text, json}, state} = send_frame(state, intent)

      assert {:ok, {:answer, %{id: "int_renew", error: %{"class" => "forbidden"}}}} =
               json |> Jason.decode!() |> Device.decode(:home)

      refute state.closed
      assert state.cert == device.cert

      assert [_first] =
               Arca.Repo.all(
                 from(c in Arca.Schemas.DeviceCertificate,
                   where: c.paired_client_id == ^device.client_id
                 )
               )
    end

    test "a replayed renewal proof on a new connection answers no challenge", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      {state, challenge} = renewing(device)
      assert {:push, _frames, _state} = send_frame(state, proof_message(challenge, device))

      assert_refused(send_frame(channel(), proof_message(challenge, device)), 4401)
    end

    test "a connect proof is not a renewal proof", %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      {state, challenge} = renewing(device)
      as_connect = %{challenge | purpose: :connect}

      assert_refused(send_frame(state, proof_message(as_connect, device)), 4401)
    end

    test "a renewal naming no certificate names nothing to challenge" do
      state = channel()

      assert_refused(
        send_frame(state, Device.encode({:renew, %{client_id: "pcl_" <> Ecto.UUID.generate()}})),
        4401
      )
    end
  end

  # ==========================================================================
  # Keepalive
  # ==========================================================================

  describe "keepalive" do
    setup [:seated]

    test "after a proof the channel pings every 30 seconds, reading the standing again", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      state = proven(device)
      {token, timer} = state.keepalive
      remaining = Process.read_timer(timer)
      assert remaining > 29_000 and remaining <= 30_000

      assert {:push, {:ping, ""}, state} =
               DeviceChannel.handle_info({DeviceChannel, :keepalive, token}, state)

      {next, next_timer} = state.keepalive
      refute next == token
      assert Process.read_timer(next_timer) > 29_000
      refute state.closed

      # A stale ping decides nothing.
      assert DeviceChannel.handle_info({DeviceChannel, :keepalive, token}, state) == {:ok, state}
    end

    test "no ping is armed before a proof", %{glass: glass} do
      {state, _challenge} = connected(glass)
      assert is_nil(state.keepalive) and is_nil(state.expiry)
    end
  end

  # ==========================================================================
  # The connect budget
  # ==========================================================================

  describe "the connect budget" do
    setup [:seated]

    test "failed connect proofs spend bounds of their own, and a spent one closes 1013", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)

      # Verified connects from here cost nothing.
      for _ <- 1..25, do: proven(device)

      # Failed ones do: twenty from here spend the connect bound.
      for _ <- 1..20 do
        glass = glass()
        {state, challenge} = connected(glass)
        assert_refused(send_frame(state, proof_message(challenge, glass)), 4401)
      end

      # The next connect finds it spent before any signature is checked,
      # a paired device's valid proof among them: closed 1013, with when
      # to retry, and nothing more counted.
      for glass <- [glass(), device] do
        {state, challenge} = connected(glass)

        assert {:stop, :normal, {1013, "rate_limited; retry_after_s=" <> seconds}, closed} =
                 send_frame(state, proof_message(challenge, glass))

        assert String.to_integer(seconds) in 1..60
        assert_one_decision(closed, "rate_limited", :none)
        assert_closed(closed)
      end

      # A pairing completion from the same address is not charged for it:
      # bad connects cannot starve completions and renewals.
      {:ok, invitation} = Sanctum.Pairing.begin(session_ctx, %{})
      {device_key, _} = :crypto.generate_key(:eddsa, :ed25519)

      assert {:ok, %{challenge: _}} =
               Sanctum.Pairing.complete(
                 Context.build(%{authenticated: false, client_ip: "127.0.0.1"}),
                 invitation.invitation_secret,
                 %{device_key: device_key}
               )
    end
  end

  # ==========================================================================
  # Refusals: 4401, a connection that has not proven its key
  # ==========================================================================

  describe "4401" do
    test "a connect without a proof is closed when its challenge's deadline passes",
         %{glass: glass} do
      {state, _challenge} = connected(glass)
      assert {token, _timer} = state.deadline
      assert_refused(DeviceChannel.handle_info({DeviceChannel, :deadline, token}, state), 4401)
    end

    test "an upgrade that never connects is closed at its deadline" do
      state = channel()
      assert {token, _timer} = state.deadline
      assert_refused(DeviceChannel.handle_info({DeviceChannel, :deadline, token}, state), 4401)
    end

    test "a deadline the connect replaced decides nothing", %{glass: glass} do
      state = channel()
      {stale, _timer} = state.deadline
      {:reply, :ok, _challenge, state} = send_frame(state, connect_message(glass))
      refute match?({^stale, _}, state.deadline)

      assert {:ok, ^state} = DeviceChannel.handle_info({DeviceChannel, :deadline, stale}, state)
      assert DeviceChannel.handle_info(:anything, state) == {:ok, state}
    end

    test "a proof after its challenge expired", %{glass: glass} do
      {state, challenge} = connected(glass)
      expired = %{challenge | expires_at: System.system_time(:millisecond) - 1}
      state = %{state | challenge: expired}

      assert_refused(send_frame(state, proof_message(expired, glass)), 4401)
    end

    test "a proof before any connect", %{glass: glass} do
      {_other, challenge} = connected(glass)
      assert_refused(send_frame(channel(), proof_message(challenge, glass)), 4401)
    end

    test "a second connect", %{glass: glass} do
      {state, _challenge} = connected(glass)
      assert_refused(send_frame(state, connect_message(glass)), 4401)
    end

    test "an intent before a proof is answered with its id and the class, then closed",
         %{glass: glass} do
      # The answer is the protocol's vector for it, byte for byte once read.
      vector =
        Enum.find(
          vectors()["messages"],
          &(&1["name"] == "an answer refusing an intent before its proof")
        )

      for state <- [channel(), elem(connected(glass), 0)] do
        intent = intent_message("int_1", "vault.create", %{"name" => "github"})
        {answer, decision} = assert_refused_answering(send_frame(state, intent))

        assert answer == vector["message"]

        assert {:ok, {:answer, %{id: "int_1", error: %{"class" => "unauthenticated"}}}} =
                 Device.decode(answer, :home)

        assert {decision.tool, decision.action} == {"vault", "create"}
      end
    end

    test "a confirmation from a client with no authenticated person is refused", %{glass: glass} do
      repeated =
        "int_2"
        |> intent_message("vault.create", %{"name" => "github"})
        |> Map.put("confirmation_id", "cnf_" <> Ecto.UUID.generate())

      confirming =
        intent_message("int_3", "confirmation.confirm", %{"id" => "cnf_1", "assertion" => %{}})

      for message <- [repeated, confirming] do
        {state, _challenge} = connected(glass)
        {answer, _decision} = assert_refused_answering(send_frame(state, message))

        assert {:ok, {:answer, %{error: %{"class" => "unauthenticated"}}}} =
                 Device.decode(answer, :home)
      end
    end

    test "any other message before a proof", %{glass: glass} do
      {device_key, _private} = :crypto.generate_key(:eddsa, :ed25519)

      messages = [
        Device.encode({:capabilities, %{capabilities: ["display"]}}),
        Device.encode({:renew, %{client_id: glass.client_id}}),
        Device.encode(
          {:pair_request,
           %{invitation_secret: :crypto.strong_rand_bytes(16), device_key: device_key}}
        )
      ]

      for message <- messages do
        assert_refused(send_frame(channel(), message), 4401)
        {state, _challenge} = connected(glass)
        assert_refused(send_frame(state, message), 4401)
      end
    end
  end

  # ==========================================================================
  # Refusals: 4400, a frame the protocol refuses by its shape
  # ==========================================================================

  describe "4400" do
    test "every glass-side refusal of the protocol's vectors" do
      glass_refusals =
        for %{"sender" => "glass", "message" => message} = vector <- vectors()["refusals"],
            do: {vector["name"], message}

      assert length(glass_refusals) > 10

      for {name, message} <- glass_refusals do
        result = send_frame(channel(), message)
        assert match?({:stop, :normal, {4400, "unauthenticated"}, _state}, result), name
        assert_refused(result, 4400)
      end
    end

    test "an intent carrying continuous data, in each field that marks it" do
      for field <- Device.continuous_fields() do
        message =
          "int_1" |> intent_message("vault.create", %{"name" => "github"}) |> Map.put(field, [])

        assert_refused(send_frame(channel(), message), 4400)
      end
    end

    test "an intent whose args are over 64 KiB" do
      filler = String.duplicate("a", 65_537)
      message = intent_message("int_1", "vault.create", %{"filler" => filler})
      assert_refused(send_frame(channel(), message), 4400)
    end

    test "a home's message sent by the glass", %{glass: glass} do
      {_state, challenge} = connected(glass)

      assert_refused(
        send_frame(channel(), Device.encode({:challenge, %{challenge: challenge}})),
        4400
      )
    end

    test "a frame that is not JSON, not an object, or not text", %{glass: glass} do
      json = Jason.encode!(connect_message(glass))

      for {frame, opcode} <- [
            {"{not json", :text},
            {"[]", :text},
            {"null", :text},
            {json, :binary}
          ] do
        assert_refused(DeviceChannel.handle_in({frame, [opcode: opcode]}, channel()), 4400)
      end
    end

    test "a malformed frame after connect", %{glass: glass} do
      {state, _challenge} = connected(glass)
      assert_refused(DeviceChannel.handle_in({"{not json", [opcode: :text]}, state), 4400)
    end

    test "a frame over 131,072 bytes is refused before it is read, however valid", %{glass: glass} do
      # At the bound, a valid connect is read and answered.
      at_bound = padded(connect_message(glass), 131_072)

      assert {:reply, :ok, {:text, _challenge}, _state} =
               DeviceChannel.handle_in({at_bound, [opcode: :text]}, channel())

      # One byte past it, the same connect is refused unread: the decision
      # is the bound's, not a decoding's.
      over = padded(connect_message(glass), 131_073)
      state = assert_refused(DeviceChannel.handle_in({over, [opcode: :text]}, channel()), 4400)

      assert [decision] = decisions_of(state.ctx.request_id)
      assert decision.reason == "The frame is larger than any device protocol message"
      assert is_nil(state.connect)

      # A frame that would never decode is refused for its size all the same.
      junk = String.duplicate("x", 131_073)
      state = assert_refused(DeviceChannel.handle_in({junk, [opcode: :binary]}, channel()), 4400)

      assert [%{reason: "The frame is larger than any device protocol message"}] =
               decisions_of(state.ctx.request_id)
    end
  end

  # ==========================================================================
  # A refusal closes the channel for good
  # ==========================================================================

  describe "after a refusal" do
    test "a frame, the deadline and a frame again record nothing and stop the connection",
         %{glass: glass} do
      state = channel()
      {token, timer} = state.deadline

      closed = assert_refused(DeviceChannel.handle_in({"{}", [opcode: :text]}, state), 4400)

      # The deadline was cancelled with the refusal, and its message, had
      # it already been sent, decides nothing.
      assert Process.read_timer(timer) == false

      assert DeviceChannel.handle_info({DeviceChannel, :deadline, token}, closed) ==
               stopped(closed)

      assert DeviceChannel.handle_in({"{}", [opcode: :text]}, closed) == stopped(closed)

      # Nothing is acted on either: a connect draws no challenge.
      assert send_frame(closed, connect_message(glass)) == stopped(closed)
      assert [_one] = decisions_of(closed.ctx.request_id)
    end

    test "after a refused proof, the connect's deadline, a proof and an intent record nothing",
         %{glass: glass} do
      {state, challenge} = connected(glass)
      {token, timer} = state.deadline

      closed = assert_refused(send_frame(state, proof_message(challenge, glass)), 4401)

      assert Process.read_timer(timer) == false

      assert DeviceChannel.handle_info({DeviceChannel, :deadline, token}, closed) ==
               stopped(closed)

      assert send_frame(closed, proof_message(challenge, glass)) == stopped(closed)

      # An intent after the close draws no answer.
      intent = intent_message("int_9", "vault.create", %{"name" => "github"})
      assert send_frame(closed, intent) == stopped(closed)
      assert [_one] = decisions_of(closed.ctx.request_id)
    end

    test "after the deadline's refusal, the same deadline again records nothing", %{glass: glass} do
      {state, _challenge} = connected(glass)
      {token, _timer} = state.deadline

      closed =
        assert_refused(DeviceChannel.handle_info({DeviceChannel, :deadline, token}, state), 4401)

      assert DeviceChannel.handle_info({DeviceChannel, :deadline, token}, closed) ==
               stopped(closed)

      assert send_frame(closed, connect_message(glass)) == stopped(closed)
      assert [_one] = decisions_of(closed.ctx.request_id)
    end

    test "a ping after the close stops the connection; before it, a ping is only answered" do
      state = channel()
      assert DeviceChannel.handle_control({"", [opcode: :ping]}, state) == {:ok, state}

      closed = assert_refused(DeviceChannel.handle_in({"{}", [opcode: :text]}, state), 4400)

      for opcode <- [:ping, :pong] do
        assert DeviceChannel.handle_control({"", [opcode: opcode]}, closed) == stopped(closed)
      end
    end

    test "a verified channel's refusal cancels its expiry and its ping" do
      session = seated(%{})
      device = pair!(session.session_ctx)
      state = proven(device)
      {_token, expiry} = state.expiry
      {_token, keepalive} = state.keepalive

      closed =
        assert_refused(
          send_frame(state, connect_message(device)),
          4401,
          "unauthenticated",
          :established
        )

      assert Process.read_timer(expiry) == false
      assert Process.read_timer(keepalive) == false
      assert is_nil(closed.expiry) and is_nil(closed.keepalive)
    end

    test "on a real connection, a frame after the refusal ends the connection's process" do
      {:ok, server} =
        start_supervised(
          {Bandit,
           plug: CyfrWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      socket = ws_open(port)

      # A frame the protocol refuses: the close frame, 4400 and its class.
      :ok = ws_send(socket, "{}")
      assert {8, <<4400::16, "unauthenticated">>} = ws_recv(socket)

      # The connection is still open, waiting for the peer's close. A
      # frame after the refusal stops it.
      :ok = ws_send(socket, "{}")
      assert :gen_tcp.recv(socket, 0, 5_000) == {:error, :closed}
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp transport_info(params \\ %{}) do
    %{
      endpoint: CyfrWeb.Endpoint,
      transport: :websocket,
      options: [],
      params: params,
      connect_info: %{peer_data: %{address: {127, 0, 0, 1}, port: 50_000, ssl_cert: nil}}
    }
  end

  # An upgraded connection, as the transport leaves it after `init/1`.
  defp channel do
    {:ok, state} = DeviceChannel.connect(transport_info())
    {:ok, state} = DeviceChannel.init(state)
    state
  end

  # A glass no person of this home paired: its device key, and a local
  # certificate for it signed under a live key this home does not hold.
  defp glass do
    {device_key, device_private} = :crypto.generate_key(:eddsa, :ed25519)
    {_live_key, live_private} = :crypto.generate_key(:eddsa, :ed25519)
    home = Sanctum.Person.home()
    now = System.system_time(:millisecond)
    client_id = Prima.UUID7.generate_id("pcl")

    {:ok, cert} =
      DeviceCert.new(
        device_key: device_key,
        client_id: client_id,
        subject: %{kind: :local, user_id: Prima.UUID7.generate_id("usr")},
        issuer: home,
        audience: home,
        athanor: Prima.UUID7.generate_id("ath"),
        not_before: now,
        expires_at: now + 3_600_000
      )

    %{cert: DeviceCert.sign(cert, live_private), client_id: client_id, private: device_private}
  end

  # A person seated in a group of their own, and the context their session
  # establishes there.
  defp seated(_context) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|channel-#{n}",
        provider: "github",
        email: "channel#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Channel #{n}")

    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(built)

    {:ok, session_ctx} =
      Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

    %{user: user, athanor: athanor, session_ctx: session_ctx}
  end

  # A device paired through the ceremony, from its own address: the shape
  # `glass/0` answers, with the certificate its home issued.
  defp pair!(session_ctx) do
    {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, invitation} = Sanctum.Pairing.begin(session_ctx, %{})
    source = "198.51.100.#{rem(System.unique_integer([:positive]), 250) + 1}"
    glass = Context.build(%{authenticated: false, client_ip: source})

    {:ok, %{challenge: challenge}} =
      Sanctum.Pairing.complete(glass, invitation.invitation_secret, %{device_key: device_key})

    {:ok, %{client_id: client_id, certificate: certificate}} =
      Sanctum.Pairing.complete(glass, invitation.invitation_secret, %{
        device_key: device_key,
        proof: Proof.sign(challenge, private)
      })

    %{cert: certificate, client_id: client_id, private: private}
  end

  # A paired device's channel after its proof verified.
  defp proven(device) do
    {state, challenge} = connected(device)
    {:push, [_standing], state} = send_frame(state, proof_message(challenge, device))
    state
  end

  # A new connection's renewal exchange, up to its challenge.
  defp renewing(device) do
    message =
      Device.encode({:renew, %{client_id: device.client_id, certificate: device.cert}})

    {:reply, :ok, {:text, json}, state} = send_frame(channel(), message)
    {:ok, {:challenge, %{challenge: challenge}}} = Device.decode(Jason.decode!(json), :home)
    {state, challenge}
  end

  # A bounded wait until `certificate` expired on this home's clock.
  defp past_expiry(certificate, tries \\ 300) do
    cond do
      System.system_time(:millisecond) >= certificate.expires_at ->
        :ok

      tries == 0 ->
        flunk("the certificate did not expire")

      true ->
        Process.sleep(10)
        past_expiry(certificate, tries - 1)
    end
  end

  defp rotate_live_key!(user_id) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, sealed} = Sanctum.Cipher.encrypt(private, Sanctum.CipherAAD.person_key(user_id, :live))

    {1, _} =
      Arca.Repo.update_all(from(p in PersonIdentity, where: p.user_id == ^user_id),
        set: [live_public_key: public, live_key_sealed: sealed]
      )

    public
  end

  defp connect_message(glass),
    do: Device.encode({:connect, %{client_id: glass.client_id, certificate: glass.cert}})

  defp proof_message(challenge, glass),
    do: Device.encode({:proof, %{proof: Proof.sign(challenge, glass.private)}})

  defp intent_message(id, operation, args),
    do: Device.encode({:intent, %{id: id, operation: operation, args: args}})

  # A glass connected and challenged: the channel's state and the challenge
  # it answered.
  defp connected(glass) do
    {:reply, :ok, {:text, json}, state} = send_frame(channel(), connect_message(glass))
    {:ok, {:challenge, %{challenge: challenge}}} = Device.decode(Jason.decode!(json), :home)
    {state, challenge}
  end

  defp send_frame(state, message),
    do: DeviceChannel.handle_in({Jason.encode!(message), [opcode: :text]}, state)

  # What the channel answers anything with once it closed.
  defp stopped(state), do: {:stop, {:shutdown, :closed}, state}

  # A refusal: the close code with the class as its reason, exactly one
  # decision for the connection's refusal, and a channel closed for good.
  defp assert_refused(result, code, class \\ "unauthenticated", caller \\ :none) do
    assert {:stop, :normal, {^code, ^class}, state} = result
    assert_one_decision(state, class, caller)
    assert_closed(state)
    state
  end

  # A refusal that answers an intent first: its frame, then as above.
  defp assert_refused_answering(result, code \\ 4401, class \\ "unauthenticated") do
    assert {:stop, :normal, {^code, ^class}, [{:text, json}], state} = result
    caller = if state.client, do: :established, else: :none
    decision = assert_one_decision(state, class, caller)
    assert_closed(state)
    {Jason.decode!(json), decision}
  end

  # Closed for good: every timer cancelled, and a frame of any kind, a
  # control frame or a timer the transport still delivers is acted on and
  # recorded never, and stops the connection.
  defp assert_closed(state) do
    assert state.closed == true
    assert is_nil(state.deadline) and is_nil(state.expiry) and is_nil(state.keepalive)

    for {frame, opcode} <- [
          {"{}", :text},
          {"{not json", :text},
          {"{}", :binary},
          {String.duplicate(" ", 131_073), :text}
        ] do
      assert DeviceChannel.handle_in({frame, [opcode: opcode]}, state) == stopped(state)
    end

    assert DeviceChannel.handle_control({"", [opcode: :ping]}, state) == stopped(state)

    for kind <- [:deadline, :expiry, :keepalive] do
      assert DeviceChannel.handle_info({DeviceChannel, kind, make_ref()}, state) ==
               stopped(state)
    end

    refusals = Enum.filter(decisions_of(state.ctx.request_id), &(&1.admission == "refused"))
    assert [_one] = refusals
  end

  # One refusal for the connection, counted by its request id, and it is
  # the refused message's, under the call id the channel assigned it:
  # refused, on the external plane, in its class, under no caller before a
  # proof and the client's after, and no request-log row of the
  # transport's.
  defp assert_one_decision(state, class, caller) do
    request_id = state.ctx.request_id
    call_id = state.call_id
    assert "call_" <> _ = call_id

    assert [decision] =
             Enum.filter(decisions_of(request_id), &(&1.admission == "refused"))

    assert decision.call_id == call_id
    assert decision.plane == "external"
    assert decision.refusal_class == class

    rows = Arca.Repo.all(from(l in Arca.Schemas.McpLog, where: l.id == ^call_id))

    case caller do
      # No caller: no actor, a null tenant, and no request-log row (the
      # table's tenant columns stay non-null).
      :none ->
        assert is_nil(decision.user_id)
        assert is_nil(decision.athanor_id)
        assert rows == []

      # The client's: its person and athanor, and the one request-log row
      # the decision writes for a caller, none of the transport's own.
      :established ->
        assert decision.user_id == state.client.user_id
        assert decision.athanor_id == state.client.athanor_id
        assert [%{status: "error"}] = rows
    end

    decision
  end

  defp decisions_of(request_id),
    do: Arca.Repo.all(from(d in Arca.Schemas.DecisionLog, where: d.request_id == ^request_id))

  # A frame of exactly `size` bytes: the message's JSON, padded with the
  # whitespace JSON allows after a value.
  defp padded(message, size) do
    json = Jason.encode!(message)
    json <> String.duplicate(" ", size - byte_size(json))
  end

  @doc false
  # A telemetry handler holding the test process's insert of a device
  # certificate past its one-second life, so the channel's check of the
  # replacement finds it expired.
  def hold_certificate_insert(_event, _measurements, %{source: "device_certificates"} = meta, me) do
    if self() == me and String.starts_with?(meta[:query] || "", "INSERT"),
      do: Process.sleep(1_100)

    :ok
  end

  def hold_certificate_insert(_event, _measurements, _metadata, _me), do: :ok

  # ---- a WebSocket client, as far as one case needs it -------------------------

  defp ws_open(port) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 5_000)

    key = Base.encode64(:crypto.strong_rand_bytes(16))

    :ok =
      :gen_tcp.send(socket, [
        "GET /device/websocket HTTP/1.1\r\n",
        "Host: localhost\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Key: #{key}\r\n",
        "Sec-WebSocket-Version: 13\r\n\r\n"
      ])

    assert headers(socket, "") =~ ~r{\AHTTP/1\.1 101}
    socket
  end

  defp headers(socket, received) do
    if String.contains?(received, "\r\n\r\n") do
      received
    else
      {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
      headers(socket, received <> more)
    end
  end

  # One masked text frame, as a client sends it.
  defp ws_send(socket, payload) when byte_size(payload) < 126 do
    mask = :crypto.strong_rand_bytes(4)
    header = <<1::1, 0::3, 1::4, 1::1, byte_size(payload)::7>>
    :gen_tcp.send(socket, [header, mask, masked(payload, mask)])
  end

  defp masked(payload, mask) do
    keys = :binary.bin_to_list(mask)

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, Enum.at(keys, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end

  # One unmasked frame, as the server sends it: its opcode and payload.
  defp ws_recv(socket) do
    {:ok, <<_fin::1, _rsv::3, opcode::4, 0::1, length::7>>} = :gen_tcp.recv(socket, 2, 5_000)

    length =
      case length do
        126 ->
          {:ok, <<extended::16>>} = :gen_tcp.recv(socket, 2, 5_000)
          extended

        short ->
          short
      end

    {:ok, payload} = if length > 0, do: :gen_tcp.recv(socket, length, 5_000), else: {:ok, ""}
    {opcode, payload}
  end
end
