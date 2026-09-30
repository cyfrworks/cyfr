# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.DeviceChannelTest do
  @moduledoc """
  The device channel before any proof verifies.

  The upgrade admits nothing and holds an unauthenticated context whose
  origin is `interactive` whatever the query says. `connect` is answered
  with a `connect` challenge bound to this home, the certificate and the
  client; every proof is refused by the verifier, which is not built. A
  refused connection is one decision, counted by the connection's request
  id, under the call id the channel assigned the refused message, with the
  class `unauthenticated`, no caller, no tenant and no request-log row, and
  the socket closes `4400` for a frame the protocol refuses by its shape or
  size and `4401` for a connection that has not proven its key, the class
  as the close reason. The refusal closes the channel for good: frames and
  a deadline the transport delivers after it record nothing.

  No WebSocket client is in the dependencies, so the transport callbacks
  are driven directly, as the transport drives them (`connect/1`,
  `init/1`, `handle_in/2`, `handle_info/2`). The endpoint's mount is read
  through `CyfrWeb.Endpoint.__sockets__/0`, and the upgrade is driven
  through the endpoint on the test adapter, which hands back the state
  `connect/1` built.
  """

  use CyfrWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Emissary.Web.DeviceChannel
  alias Prima.{Device, DeviceCert}
  alias Prima.DeviceCert.{Challenge, Proof}

  @vectors Path.expand("../../../../../tests/fixtures/device.json", __DIR__)
  @external_resource @vectors

  setup do
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

    test "the mount caps a frame, and its idle timeout sits above the proof deadline" do
      {"/device", DeviceChannel, opts} =
        Enum.find(CyfrWeb.Endpoint.__sockets__(), &match?({"/device", _, _}, &1))

      assert opts[:websocket][:max_frame_size] == 131_072
      assert opts[:websocket][:timeout] == 90_000
      assert opts[:websocket][:timeout] > Challenge.lifetime_ms()
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
      assert challenge.home == Sanctum.origin()
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

    test "a proof is refused by the verifier, which is not built", %{glass: glass} do
      {state, challenge} = connected(glass)
      state = assert_refused(send_frame(state, proof_message(challenge, glass)), 4401)
      assert is_nil(state.client)
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
    test "a frame, the deadline and a frame again record nothing: one decision for the connection",
         %{glass: glass} do
      state = channel()
      {token, timer} = state.deadline

      closed = assert_refused(DeviceChannel.handle_in({"{}", [opcode: :text]}, state), 4400)

      # The deadline was cancelled with the refusal, and its message, had
      # it already been sent, decides nothing.
      assert Process.read_timer(timer) == false
      assert DeviceChannel.handle_info({DeviceChannel, :deadline, token}, closed) == {:ok, closed}
      assert DeviceChannel.handle_in({"{}", [opcode: :text]}, closed) == {:ok, closed}

      # Nothing is acted on either: a connect draws no challenge.
      assert send_frame(closed, connect_message(glass)) == {:ok, closed}
      assert [_one] = decisions_of(closed.ctx.request_id)
    end

    test "after a refused proof, the connect's deadline, a proof and an intent record nothing",
         %{glass: glass} do
      {state, challenge} = connected(glass)
      {token, timer} = state.deadline

      closed = assert_refused(send_frame(state, proof_message(challenge, glass)), 4401)

      assert Process.read_timer(timer) == false
      assert DeviceChannel.handle_info({DeviceChannel, :deadline, token}, closed) == {:ok, closed}
      assert send_frame(closed, proof_message(challenge, glass)) == {:ok, closed}

      # An intent after the close draws no answer.
      intent = intent_message("int_9", "vault.create", %{"name" => "github"})
      assert send_frame(closed, intent) == {:ok, closed}
      assert [_one] = decisions_of(closed.ctx.request_id)
    end

    test "after the deadline's refusal, the same deadline again records nothing", %{glass: glass} do
      {state, _challenge} = connected(glass)
      {token, _timer} = state.deadline

      closed =
        assert_refused(DeviceChannel.handle_info({DeviceChannel, :deadline, token}, state), 4401)

      assert DeviceChannel.handle_info({DeviceChannel, :deadline, token}, closed) == {:ok, closed}
      assert send_frame(closed, connect_message(glass)) == {:ok, closed}
      assert [_one] = decisions_of(closed.ctx.request_id)
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

  # A paired glass: its device key, and a local certificate for it signed
  # under a live key of this home.
  defp glass do
    {device_key, device_private} = :crypto.generate_key(:eddsa, :ed25519)
    {_live_key, live_private} = :crypto.generate_key(:eddsa, :ed25519)
    home = Sanctum.origin()
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

  # A refusal: the close code with the class as its reason, exactly one
  # decision for the connection, and a channel closed for good.
  defp assert_refused(result, code) do
    assert {:stop, :normal, {^code, "unauthenticated"}, state} = result
    assert_one_decision(state)
    assert_closed(state)
    state
  end

  # A refusal that answers an intent first: its frame, then as above.
  defp assert_refused_answering(result) do
    assert {:stop, :normal, {4401, "unauthenticated"}, [{:text, json}], state} = result
    decision = assert_one_decision(state)
    assert_closed(state)
    {Jason.decode!(json), decision}
  end

  # Closed for good: its deadline cancelled, and a frame of any kind or a
  # deadline the transport still delivers is acted on and recorded never.
  defp assert_closed(state) do
    assert state.closed == true
    assert is_nil(state.deadline)

    for {frame, opcode} <- [
          {"{}", :text},
          {"{not json", :text},
          {"{}", :binary},
          {String.duplicate(" ", 131_073), :text}
        ] do
      assert DeviceChannel.handle_in({frame, [opcode: opcode]}, state) == {:ok, state}
    end

    assert DeviceChannel.handle_info({DeviceChannel, :deadline, make_ref()}, state) ==
             {:ok, state}

    assert [_one] = decisions_of(state.ctx.request_id)
  end

  # One decision for the whole connection, counted by its request id, and
  # it is the refused message's, under the call id the channel assigned
  # it: refused, on the external plane, as `unauthenticated`, with no
  # caller, no tenant and no request-log row of the transport's.
  defp assert_one_decision(state) do
    request_id = state.ctx.request_id
    call_id = state.call_id
    assert "call_" <> _ = call_id
    assert [decision] = decisions_of(request_id)
    assert decision.call_id == call_id
    assert decision.admission == "refused"
    assert decision.plane == "external"
    assert decision.refusal_class == "unauthenticated"
    assert is_nil(decision.user_id)
    assert is_nil(decision.athanor_id)

    assert Arca.Repo.all(
             from(l in Arca.Schemas.McpLog,
               where: l.id == ^call_id or l.request_id == ^request_id
             )
           ) == []

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
end
