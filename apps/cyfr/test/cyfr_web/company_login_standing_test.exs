# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.CompanyLoginStandingTest do
  @moduledoc """
  The company sign-in a CYFR requires, held on every holder of a person's
  standing outside the console's pages, at a CYFR whose company issuer is
  its OpenID Connect issuer.

  A retained context past the caller bound is refused at the guard once
  its person lapsed, so a running Aqua turn's next protected step is
  refused within the bound, and a fresh one is used as it is. An open
  `subscriptions/listen` stream ends at its first revalidation after a
  configuration change, answering its request with the refusal's
  sentence, and the session stands. The HTTP API answers a lapsed
  person's session token and the API key they made `403` with the
  refusal, and admits both once they stand again. A lapsed person's
  paired device is closed `1013`, to try again, with no `revoke`, and its
  pairing stands.
  """

  # Installs the company sign-in's settings and the caller bound, which
  # are application environment.
  use Emissary.Web.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias CyfrWeb.ContextGuard
  alias Emissary.Web.DeviceChannel
  alias Prima.Device
  alias Prima.DeviceCert.Proof
  alias Sanctum.Context
  alias Sanctum.Tenancy.Athanors

  @issuer "https://idp.example.com"

  setup do
    keys = [
      {:sanctum, :company_login},
      {:sanctum, :oidc_issuer},
      {:sanctum, :caller_memo_ttl_ms},
      {:ueberauth, Ueberauth}
    ]

    previous = Map.new(keys, fn {app, key} -> {{app, key}, Application.fetch_env(app, key)} end)

    on_exit(fn ->
      Arca.Cache.delete_match({:established, :_, :_})

      for {{app, key}, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    Application.put_env(:sanctum, :oidc_issuer, @issuer)
    client!("cid")
    Application.put_env(:sanctum, :company_login, %{mode: :join, days: nil, issuer: :oidc})
    :ok
  end

  # The `oidcc` client the company's issuer knows this CYFR by: changing
  # its id is a configuration change, under which no binding stands.
  defp client!(client_id) do
    Application.put_env(:ueberauth, Ueberauth,
      providers: [
        oidcc:
          {Ueberauth.Strategy.Oidcc,
           issuer: :cyfr_oidc, client_id: client_id, client_secret: "csec"}
      ]
    )
  end

  # The person's company sign-in, given under the configuration this CYFR
  # names now.
  defp stands!(user_id) do
    {:ok, {client_id, _secret}} = Sanctum.Auth.OIDC.client_credentials()

    assert {:ok, _bound} =
             Arca.CompanyAuthorizations.bind(
               Prima.Actor.system(),
               %{
                 user_id: user_id,
                 configuration: Jason.encode!(["oidc", @issuer, client_id]),
                 subject: "sub-#{System.unique_integer([:positive])}"
               },
               verify: fn -> :ok end
             )

    :ok
  end

  # A person seated in the test athanor, who stands, and their session.
  defp standing_person! do
    ctx = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
    stands!(ctx.user_id)
    {:ok, session} = Sanctum.Session.create(ctx)
    {ctx, session}
  end

  defp session_stands?(token), do: match?({:ok, _ctx}, Sanctum.Session.load(token))

  # ==========================================================================
  # A retained context
  # ==========================================================================

  describe "a context a running turn holds" do
    test "past the caller bound is refused once its person lapsed; a fresh one is used as it is" do
      Application.put_env(:sanctum, :caller_memo_ttl_ms, 2_000)
      {_ctx, session} = standing_person!()
      {:ok, ctx} = Sanctum.Caller.establish(session.token, refresh: false)

      client!("cid-rotated")

      fresh = %{ctx | validated_at: DateTime.utc_now()}
      assert {:ok, ^fresh} = ContextGuard.check(fresh)

      held = %{ctx | validated_at: DateTime.add(DateTime.utc_now(), -2_000, :millisecond)}
      assert {:error, :company_login_required} = ContextGuard.check(held)
      assert session_stands?(session.token)
    end
  end

  # ==========================================================================
  # An open event stream
  # ==========================================================================

  describe "an open subscriptions/listen" do
    setup do
      # The stream's own window, short: a case that leaves one open ends.
      Cyfr.Test.Settings.put("mcp_subscription_max_ms", 5_000)
      :ok
    end

    defp open_listen(conn, token, id) do
      Task.async(fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> token)
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "method" => "subscriptions/listen",
          "params" => %{"notifications" => %{"toolsListChanged" => true}}
        })
      end)
    end

    # The listen in `task` waits in its loop with nothing left to take:
    # acknowledged and watching its caller's standing.
    defp await_open(task) do
      wait_until(
        fn ->
          match?(
            [
              current_function: {Emissary.Web.MCPController, :listen_loop, 4},
              message_queue_len: 0
            ],
            Process.info(task.pid, [:current_function, :message_queue_len])
          )
        end,
        2_000,
        "the listen to wait in its loop"
      )
    end

    defp last_frame(conn) do
      conn.resp_body
      |> String.split("\n\n", trim: true)
      |> Enum.reject(&(&1 == ":"))
      |> List.last()
      |> String.replace_prefix("data: ", "")
      |> Jason.decode!()
    end

    test "ends at its first revalidation after a configuration change, with the refusal's sentence",
         %{conn: conn} do
      {_ctx, session} = standing_person!()
      task = open_listen(conn, session.token, 21)
      await_open(task)

      client!("cid-rotated")
      send(task.pid, ContextGuard.recheck_message())
      conn = Task.await(task, 10_000)

      refusal = Prima.Refusal.classify(:company_login_required)
      code = Prima.MCP.Message.refusal_code(refusal, :transport, nil)

      assert %{"id" => 21, "error" => %{"code" => wire, "message" => message}} = last_frame(conn)
      assert message == Prima.Refusal.message(:company_login_required)
      assert wire == Prima.MCP.Message.error_code(code)
      assert session_stands?(session.token)
    end
  end

  # ==========================================================================
  # The HTTP API
  # ==========================================================================

  describe "the HTTP API" do
    defp api(conn, bearer) do
      conn
      |> put_req_header("authorization", "Bearer " <> bearer)
      |> get("/api/executions/exec_nope/events")
    end

    test "answers a lapsed person's session and API key 403 with the refusal, and admits both once they stand",
         %{conn: conn} do
      {ctx, session} = standing_person!()
      name = "company-#{System.unique_integer([:positive])}"
      {:ok, %{api_key: raw}} = Sanctum.TestContext.create_key(ctx, %{name: name, type: :service})

      client!("cid-rotated")

      for bearer <- [session.token, raw] do
        assert json_response(api(conn, bearer), 403) == %{
                 "code" => "forbidden",
                 "message" => Prima.Refusal.message(:company_login_required)
               }
      end

      # A company sign-in under the configuration this CYFR names now.
      stands!(ctx.user_id)

      for bearer <- [session.token, raw] do
        admitted = api(conn, bearer)

        # Past the plug, the stream's controller answers: no such execution.
        assert json_response(admitted, 404)["code"] == "not_found"
        assert admitted.assigns.context.user_id == ctx.user_id
      end
    end
  end

  # ==========================================================================
  # A paired device
  # ==========================================================================

  describe "a paired device" do
    setup do
      Prima.Test.RateLimiter.reset!()
      on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    end

    # A person seated in a group of their own, who stands, and the context
    # their session establishes there.
    defp seated! do
      n = System.unique_integer([:positive])

      {:ok, user} =
        Sanctum.Test.People.linked(%{
          id: "github|https://github.com|company-device-#{n}",
          provider: "github",
          email: "company-device#{n}@example.com",
          verified: true
        })

      {:ok, athanor} = Athanors.create_group(user.id, "Company device #{n}")
      stands!(user.id)

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
      {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)
      %{user: user, athanor: athanor, session_ctx: ctx}
    end

    # A device paired through the ceremony, from its own address.
    defp pair!(session_ctx) do
      {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, invitation} =
        Sanctum.TestContext.confirming(
          session_ctx,
          &Sanctum.Pairing.begin(&1, %{"key_digest" => Device.key_digest(device_key)})
        )

      glass = Context.build(%{authenticated: false, client_ip: "198.51.100.61"})

      {:ok, %{challenge: challenge}} =
        Sanctum.Pairing.complete(glass, invitation.invitation_secret, %{device_key: device_key})

      {:ok, %{client_id: client_id, certificate: certificate}} =
        Sanctum.Pairing.complete(glass, invitation.invitation_secret, %{
          device_key: device_key,
          proof: Proof.encode(Proof.sign(challenge, private))
        })

      %{cert: certificate, client_id: client_id, private: private}
    end

    # The device's channel after its proof verified, driven through the
    # transport's callbacks as the transport drives them.
    defp proven(device) do
      info = %{
        endpoint: CyfrWeb.Endpoint,
        transport: :websocket,
        options: [],
        params: %{},
        connect_info: %{peer_data: %{address: {127, 0, 0, 1}, port: 50_000, ssl_cert: nil}}
      }

      {:ok, state} = DeviceChannel.connect(info)
      {:ok, state} = DeviceChannel.init(state)

      connect =
        Device.encode({:connect, %{client_id: device.client_id, certificate: device.cert}})

      {:reply, :ok, {:text, json}, state} = frame(state, connect)
      {:ok, {:challenge, %{challenge: challenge}}} = Device.decode(Jason.decode!(json), :home)

      proof = Device.encode({:proof, %{proof: Proof.sign(challenge, device.private)}})
      {:push, [_standing], state} = frame(state, proof)
      state
    end

    defp frame(state, message),
      do: DeviceChannel.handle_in({Jason.encode!(message), [opcode: :text]}, state)

    test "of a lapsed person is closed 1013 with the refusal and no revoke, and the pairing stands" do
      %{user: user, athanor: athanor, session_ctx: session_ctx} = seated!()
      device = pair!(session_ctx)
      state = proven(device)
      {token, _timer} = state.keepalive

      client!("cid-rotated")

      # Four elements: a close with no frame before it, so no `revoke`.
      assert {:stop, :normal, {1013, "forbidden"}, closed} =
               DeviceChannel.handle_info({DeviceChannel, :keepalive, token}, state)

      assert closed.closed

      assert [decision] =
               Arca.Repo.all(
                 from(d in Arca.Schemas.DecisionLog,
                   where: d.request_id == ^closed.ctx.request_id and d.admission == "refused"
                 )
               )

      assert decision.refusal_class == "forbidden"
      assert decision.reason == Prima.Refusal.message(:company_login_required)
      assert decision.user_id == user.id

      assert {:ok, [%{id: client_id, standing: "active"}]} =
               Arca.PairedClients.list(Prima.Actor.in_athanor(athanor.id),
                 user_id: user.id,
                 standing: :all
               )

      assert client_id == device.client_id
    end
  end
end
