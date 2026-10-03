# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.PairLiveTest do
  @moduledoc """
  `/pair`, the page a pairing code opens on a new glass: sessionless, it
  completes the pairing through `pairing.complete` under an
  unauthenticated context it builds itself, with the caller's address,
  so a browser holding neither a cookie nor a certificate pairs, and a
  session cookie of another person the browser still holds never chooses
  the person: the invitation does. Its answer is the certificate the
  glass then connects the device channel under. A pairing whose answer
  never reached the browser was issued once, and the same code then says
  it was already used.

  The page's script is the browser's half: here its two events are sent
  as the hook sends them (`pair_start`, `pair_proof`), signed by a device
  key made in the test.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Emissary.Web.DeviceChannel
  alias Prima.{Device, DeviceCert}
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.Identity.Encoding
  alias Sanctum.Context

  setup do
    Prima.RateLimiter.reset()
    on_exit(fn -> Prima.RateLimiter.reset() end)
    :ok
  end

  # A person seated in their own athanor, and a pairing code they began
  # under a session and a proven confirmation.
  defp invited! do
    user = test_user()
    {:ok, athanor} = Sanctum.Tenancy.Athanors.create_group(user.user_id, "Pair #{user.namespace}")

    built =
      Context.build(
        user_id: user.user_id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(built)
    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

    {:ok, %{invitation_url: url}} =
      Sanctum.TestContext.confirming(
        ctx,
        &Grimoire.call_external("pairing", &1, %{"action" => "begin"})
      )

    %URI{path: "/pair", fragment: "code=" <> code} = URI.parse(url)
    %{user: user, athanor: athanor, ctx: ctx, code: code}
  end

  # The glass's half of the ceremony, as the hook drives it: its key, the
  # challenge, its proof, and the answer.
  defp pair(view, code, {device_key, private}) do
    key = Encoding.b64(device_key)
    render_hook(view, "pair_start", %{"invitation_secret" => code, "device_key" => key})

    case reply(view) do
      %{challenge: challenge} ->
        {:ok, challenge} = Challenge.decode(challenge)
        proof = Proof.encode(Proof.sign(challenge, private))

        render_hook(view, "pair_proof", %{
          "invitation_secret" => code,
          "device_key" => key,
          "proof" => proof
        })

        reply(view)

      refused ->
        refused
    end
  end

  defp reply(view) do
    assert_reply(view, reply)
    reply
  end

  defp key_pair, do: :crypto.generate_key(:eddsa, :ed25519)

  defp paired_clients(ctx) do
    {:ok, %{clients: clients}} =
      Grimoire.call_external("pairing", ctx, %{"action" => "list"})

    clients
  end

  test "a browser with neither cookie nor certificate pairs, under a context it builds itself",
       %{conn: conn} do
    %{user: user, athanor: athanor, code: code} = invited!()

    {:ok, view, html} = live(conn, "/pair")
    assert html =~ ~s(data-glass="pair")
    assert html =~ "Pair this device"

    # The context the page holds: no person, no athanor, no session, and
    # the caller's own address.
    ctx = :sys.get_state(view.pid).socket.assigns.context
    assert %Context{user_id: nil, athanor_id: nil, authenticated: false} = ctx
    assert Enum.empty?(ctx.permissions)
    assert is_nil(ctx.auth_method) and is_nil(ctx.session_token_hash)
    assert ctx.client_ip == "127.0.0.1"

    {device_key, _private} = keys = key_pair()
    assert %{client_id: client_id, certificate: certificate} = pair(view, code, keys)

    {:ok, certificate} = DeviceCert.decode(certificate)
    assert certificate.subject == %{kind: :local, user_id: user.user_id}
    assert certificate.athanor == athanor.id
    assert certificate.device_key == device_key
    assert certificate.client_id == client_id
    assert render(view) =~ ~s(data-test="pair-paired")
  end

  test "a leftover session of another person is ignored: the client is the person the code names",
       %{conn: conn} do
    %{user: user, ctx: ctx, code: code} = invited!()
    stranger = test_user()
    conn = log_in_user(conn, stranger)

    {:ok, view, html} = live(conn, "/pair")
    refute html =~ stranger.email
    assert is_nil(:sys.get_state(view.pid).socket.assigns.context.user_id)

    assert %{client_id: client_id, certificate: certificate} = pair(view, code, key_pair())
    {:ok, certificate} = DeviceCert.decode(certificate)
    assert certificate.subject.user_id == user.user_id
    assert [%{client_id: ^client_id}] = paired_clients(ctx)
  end

  test "the certificate answered connects the device channel", %{conn: conn} do
    %{athanor: athanor, code: code} = invited!()
    {:ok, view, _html} = live(conn, "/pair")
    {_device_key, private} = keys = key_pair()
    %{client_id: client_id, certificate: certificate} = pair(view, code, keys)
    {:ok, certificate} = DeviceCert.decode(certificate)

    {:ok, state} =
      DeviceChannel.connect(%{
        endpoint: CyfrWeb.Endpoint,
        transport: :websocket,
        options: [],
        params: %{},
        connect_info: %{peer_data: %{address: {127, 0, 0, 1}, port: 50_000, ssl_cert: nil}}
      })

    {:ok, state} = DeviceChannel.init(state)

    connect = Device.encode({:connect, %{client_id: client_id, certificate: certificate}})

    assert {:reply, :ok, {:text, json}, state} =
             DeviceChannel.handle_in({Jason.encode!(connect), [opcode: :text]}, state)

    {:ok, {:challenge, %{challenge: challenge}}} = Device.decode(Jason.decode!(json), :home)
    proof = Device.encode({:proof, %{proof: Proof.sign(challenge, private)}})

    assert {:push, [{:text, standing}], state} =
             DeviceChannel.handle_in({Jason.encode!(proof), [opcode: :text]}, state)

    assert {:ok, {:standing, %{client_id: ^client_id, athanor: athanor_id}}} =
             Device.decode(Jason.decode!(standing), :home)

    assert athanor_id == athanor.id
    assert state.client.client_id == client_id
  end

  test "a browser that closed before the answer was paired once, and the same code then says so",
       %{conn: conn} do
    %{ctx: ctx, code: code} = invited!()

    # The proof is sent, the pairing issued, and the browser goes before it
    # reads the answer.
    {:ok, first, _html} = live(conn, "/pair")
    {device_key, private} = key_pair()
    key = Encoding.b64(device_key)
    render_hook(first, "pair_start", %{"invitation_secret" => code, "device_key" => key})
    %{challenge: challenge} = reply(first)
    {:ok, challenge} = Challenge.decode(challenge)

    render_hook(first, "pair_proof", %{
      "invitation_secret" => code,
      "device_key" => key,
      "proof" => Proof.encode(Proof.sign(challenge, private))
    })

    GenServer.stop(first.pid, :normal)

    # Opened again from the same code: the explicit answer, and no second
    # device.
    {:ok, again, _html} = live(conn, "/pair")
    assert %{error: sentence} = pair(again, code, key_pair())
    assert sentence =~ "already used"
    assert render(again) =~ ~s(data-test="pair-error")
    assert [_one] = paired_clients(ctx)
  end

  test "a code whose person's keys are at another home answers what that home is to certify, and pairs nothing without its certificate",
       %{conn: conn} do
    %{user: user, athanor: athanor, ctx: ctx, code: code} = invited!()

    # From here the person is this home's remote person: their keys are at
    # another home, which certifies their devices.
    Arca.Repo.delete_all(
      from(p in Arca.Schemas.PersonIdentity, where: p.user_id == ^user.user_id)
    )

    {:ok, _} =
      Arca.PersonIdentities.create(Prima.Actor.system(), %{
        user_id: user.user_id,
        provenance: "remote",
        identifier: "per_" <> String.duplicate("ab", 32),
        directory_url: "https://dir.example"
      })

    {device_key, private} = key_pair()
    key = Encoding.b64(device_key)
    {:ok, view, _html} = live(conn, "/pair")
    render_hook(view, "pair_start", %{"invitation_secret" => code, "device_key" => key})

    assert %{challenge: challenge, certify: certify} = reply(view)

    assert certify == %{
             audience: Sanctum.Person.home(),
             athanor: athanor.id,
             client_id: challenge["client_id"]
           }

    {:ok, held} = Challenge.decode(challenge)

    render_hook(view, "pair_proof", %{
      "invitation_secret" => code,
      "device_key" => key,
      "proof" => Proof.encode(Proof.sign(held, private))
    })

    assert %{error: sentence} = reply(view)
    assert sentence =~ "bring the certificate"
    assert paired_clients(ctx) == []
  end

  test "the completion is decided by the gate, and no decision holds the code", %{conn: conn} do
    %{code: code} = invited!()
    {:ok, view, _html} = live(conn, "/pair")
    assert %{certificate: _} = pair(view, code, key_pair())

    # Two admitted completions, the challenge and the proof, with no
    # caller: the invitation named the person.
    decided =
      Arca.Repo.all(
        from(d in Arca.Schemas.DecisionLog,
          where: d.tool == "pairing" and d.action == "complete",
          select: {d.admission, d.user_id, d.reason}
        )
      )

    assert [{"admitted", nil, _}, {"admitted", nil, _}] = decided
    refute inspect(decided) =~ code

    # A caller that is no one writes no request-log row; the begin's own
    # rows are the pairing tool's to keep clean (`Sanctum.Providers.PairingTest`).
    refute Arca.Repo.exists?(
             from(l in Arca.Schemas.McpLog, where: l.tool == "pairing" and l.action == "complete")
           )
  end
end
