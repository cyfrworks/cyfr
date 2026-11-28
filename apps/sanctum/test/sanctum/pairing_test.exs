# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PairingTest do
  @moduledoc """
  The devices connected here, which changes need a fresh confirmation,
  and which clients can give one (`Sanctum.Pairing`). A device comes here
  by its hello (`Sanctum.Test.Devices`, against a scripted directory); its
  certificate is renewed through its channel's renewal exchange alone,
  under the head this CYFR holds and with its proof consumed once; the
  person revokes it under a fresh confirmation and lists their devices.
  """

  # The directory seam, the setup token, the directory setting and the
  # access mode are process-wide.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{DeviceCertificate, User}
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Sanctum.{Context, DeviceCerts, Pairing}
  alias Sanctum.Test.{DirectoryServer, Devices}

  @token String.duplicate("6a", 32)
  @source "198.51.100.20"

  @sensitive [
    :credential_entry,
    :credential_issuance,
    :credential_sharing,
    :vault_unlock,
    :home_transfer,
    :pairing_revocation,
    :pairing_readmission,
    :restore_reenable,
    :program_definition,
    :question_always_any,
    :directory_tombstone,
    :platform_admin_marking
  ]

  setup_all do
    %{tls: DirectoryServer.tls()}
  end

  setup %{tls: tls} = tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Cache.init()
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    DirectoryServer.listen!()
    DirectoryServer.seam!(tls)
    dir = DirectoryServer.start!(tls)
    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Prima.Test.Env.put_app_env(:sanctum, :directory_url, dir.url)
    Prima.Test.Env.put_app_env(:sanctum, :access_mode, :public)
    Arca.Repo.delete_all(User)

    account = DirectoryServer.account!(dir.dir, dir.url)
    device = Devices.admitted!(account, List.last(account.devices), {:setup, @token})
    %{dir: dir, account: account, device: device, session_ctx: session_ctx!(device)}
  end

  defp ctx(attrs) do
    Context.build(
      Map.merge(
        %{user_id: "usr_pair", athanor_id: "ath_pair", authenticated: true, permissions: [:*]},
        Map.new(attrs)
      )
    )
  end

  # The device's person's own browser session, focused on their athanor.
  defp session_ctx!(%{user: user, certificate: certificate}) do
    built =
      Context.build(
        user_id: user.id,
        provider: "passkey",
        athanor_id: certificate.athanor,
        permissions: [:*],
        auth_method: :session,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(built)

    {:ok, session_ctx} =
      Sanctum.Caller.establish(session.token, focus: certificate.athanor, refresh: false)

    session_ctx
  end

  defp signed(challenge, private), do: Proof.encode(Proof.sign(challenge, private))

  defp challenge(device, purpose, overrides \\ []) do
    certificate = device.certificate

    {:ok, challenge} =
      [
        purpose: purpose,
        home: certificate.audience,
        athanor: certificate.athanor,
        client_id: device.client_id,
        device_key: elem(device.key, 0),
        nonce: :crypto.strong_rand_bytes(Challenge.nonce_bytes()),
        now: System.system_time(:millisecond)
      ]
      |> Keyword.merge(overrides)
      |> Challenge.new()

    challenge
  end

  defp renewing!(device, challenge) do
    {:ok, ctx} =
      DeviceCerts.verify_connect(
        %{client_id: device.client_id, certificate: device.certificate, source: @source},
        Proof.sign(challenge, elem(device.key, 1)),
        challenge
      )

    ctx
  end

  defp renewal(device, challenge) do
    %{
      client_id: device.client_id,
      device_key: elem(device.key, 0),
      proof: signed(challenge, elem(device.key, 1))
    }
  end

  defp remove!(session_ctx, client_id) do
    session_ctx
    |> Sanctum.TestContext.confirmed(
      :pairing_revocation,
      Sanctum.TestContext.pairing_revocation(session_ctx, client_id)
    )
    |> Pairing.remove(client_id)
  end

  # A change the person asks under their session, confirmed by `by`,
  # another device of their account here, as a device confirms over its
  # channel (`confirmation.request`, then `confirmation.confirm` with its
  # answer); then made again naming the record. The person keeps the
  # account their devices are keys of.
  defp device_confirmed!(session_ctx, by, change) do
    {:error, {:confirmation_required, %{id: id}}} = change.(session_ctx)
    ref = Prima.Confirmation.ref(id)
    device_ctx = Devices.connected!(by)

    {:ok, %{request: encoded}} =
      Sanctum.Gate.call_external("confirmation", device_ctx, %{
        "action" => "request",
        "ref" => ref
      })

    {:ok, request} = Prima.SignIn.decode(encoded)
    answer = request |> Devices.answer(by.key) |> Prima.SignIn.DeviceAnswer.encode()

    {:ok, %{state: "confirmed"}} =
      Sanctum.Gate.call_external("confirmation", device_ctx, %{
        "action" => "confirm",
        "ref" => ref,
        "answer" => answer
      })

    change.(%{session_ctx | confirmation_id: id})
  end

  # Whole rows of the person's clients, oldest first: which client, what
  # it stands on and its standing.
  defp standings(user_id) do
    from(c in Arca.Schemas.PairedClient,
      where: c.user_id == ^user_id,
      order_by: [asc: c.inserted_at, asc: c.id],
      select: {c.id, c.source_kind, c.standing}
    )
    |> Arca.Repo.all()
  end

  describe "the action table" do
    test "is closed" do
      assert Pairing.actions() == Enum.sort([:grant, :approval | @sensitive])
    end

    test "a grant and an approval need the session alone; every other action is sensitive" do
      refute Pairing.sensitive?(:grant)
      refute Pairing.sensitive?(:approval)
      for action <- @sensitive, do: assert(Pairing.sensitive?(action), inspect(action))

      assert_raise FunctionClauseError, fn -> Pairing.sensitive?(:device_pairing) end
    end
  end

  describe "can_confirm?/1" do
    test "a signed-in browser session has a person behind it who can give a proof" do
      assert Pairing.can_confirm?(ctx(auth_method: :session))
    end

    test "a client with no person behind it confirms nothing" do
      nobody = [
        ctx(auth_method: :session, plane: :guest),
        ctx(auth_method: :api_key),
        ctx(auth_method: :tincture),
        ctx(auth_method: :webhook),
        ctx(auth_method: :scheduled),
        ctx(auth_method: :system),
        ctx(auth_method: :session, anonymous: true),
        Context.build(%{auth_method: :session, authenticated: false})
      ]

      for context <- nobody,
          do: refute(Pairing.can_confirm?(context), inspect(context.auth_method))
    end

    test "a paired device confirms while its paired client stands, read from the store", %{
      device: device,
      session_ctx: session_ctx
    } do
      ctx = Devices.connected!(device)
      assert Pairing.can_confirm?(ctx)

      {:ok, _row} = remove!(session_ctx, device.client_id)
      refute Pairing.can_confirm?(ctx)
    end
  end

  describe "renew/2" do
    test "issues a replacement under the stored key while the client stands", %{device: device} do
      challenge = challenge(device, :renew)
      ctx = renewing!(device, challenge)

      assert {:ok, %{client_id: client_id, certificate: renewed}} =
               Pairing.renew(ctx, renewal(device, challenge))

      assert client_id == device.client_id
      assert renewed.kid == device.certificate.kid
      assert renewed.expires_at >= device.certificate.expires_at
      assert {:ok, _ctx} = DeviceCerts.verify_request(renewed, ctx)

      assert [_first, _renewed] =
               Arca.Repo.all(
                 from(c in DeviceCertificate, where: c.paired_client_id == ^client_id)
               )
    end

    test "a renewal proof is consumed once", %{device: device} do
      challenge = challenge(device, :renew)
      ctx = renewing!(device, challenge)
      request = renewal(device, challenge)

      assert {:ok, _} = Pairing.renew(ctx, request)
      assert Pairing.renew(ctx, request) == {:error, :replayed}
    end

    test "a proof of another purpose, client or key is refused", %{device: device} do
      ctx = renewing!(device, challenge(device, :renew))
      {other_key, other_private} = :crypto.generate_key(:eddsa, :ed25519)

      for {challenge, private} <- [
            {challenge(device, :connect), elem(device.key, 1)},
            {challenge(device, :renew, client_id: "pcl_another"), elem(device.key, 1)},
            {challenge(device, :renew, home: "https://elsewhere.example"), elem(device.key, 1)},
            {challenge(device, :renew, device_key: other_key), other_private}
          ] do
        assert Pairing.renew(ctx, %{
                 client_id: device.client_id,
                 device_key: elem(device.key, 0),
                 proof: signed(challenge, private)
               }) == {:error, :proof_refused}
      end
    end

    test "a removed client renews nothing", %{device: device, session_ctx: session_ctx} do
      challenge = challenge(device, :renew)
      ctx = renewing!(device, challenge)
      {:ok, _} = remove!(session_ctx, device.client_id)

      assert Pairing.renew(ctx, renewal(device, challenge)) == {:error, :revoked}
    end

    test "only the renewal exchange's context renews: an ordinary device context does not", %{
      device: device,
      session_ctx: session_ctx
    } do
      challenge = challenge(device, :renew)
      request = renewal(device, challenge)

      assert Pairing.renew(Devices.connected!(device), request) ==
               {:error, :renewal_exchange_only}

      assert Pairing.renew(session_ctx, request) == {:error, :renewal_exchange_only}
    end
  end

  describe "remove/2" do
    test "ends the person's own device with its certificates, as removed", %{
      device: device,
      session_ctx: session_ctx
    } do
      assert {:ok, %{standing: "removed"}} = remove!(session_ctx, device.client_id)

      assert Arca.Repo.all(
               from(c in DeviceCertificate,
                 where: c.paired_client_id == ^device.client_id and c.state == "active"
               )
             ) == []
    end

    # The record names the client as its person sees it, never by its id.
    test "asks a confirmation whose preview names the client by its name", %{
      device: device,
      session_ctx: session_ctx
    } do
      assert {:error, {:confirmation_required, %{id: id}}} =
               Pairing.remove(session_ctx, device.client_id)

      {:ok, record} =
        Arca.PendingConfirmations.get(Context.actor(session_ctx), Prima.Confirmation.ref(id))

      {:ok, home} = Prima.Identity.Encoding.canonical_home(Sanctum.origin())
      {:ok, athanor} = Sanctum.Tenancy.Athanors.get(session_ctx.athanor_id)

      assert Jason.decode!(record.preview) == %{
               "home" => home,
               "athanor" => athanor.name,
               "operation" => "pairing.remove",
               "resource" => "Test device"
             }
    end

    # A name the preview cannot hold names nothing, and the removal is
    # asked all the same.
    test "names nothing for a client whose name the preview cannot hold", %{
      device: device,
      session_ctx: session_ctx
    } do
      {1, _} =
        Arca.Repo.update_all(
          from(c in Arca.Schemas.PairedClient, where: c.id == ^device.client_id),
          set: [display_name: "Phone\n2"]
        )

      assert {:error, {:confirmation_required, %{id: id}}} =
               Pairing.remove(session_ctx, device.client_id)

      {:ok, record} =
        Arca.PendingConfirmations.get(Context.actor(session_ctx), Prima.Confirmation.ref(id))

      {:ok, home} = Prima.Identity.Encoding.canonical_home(Sanctum.origin())
      {:ok, athanor} = Sanctum.Tenancy.Athanors.get(session_ctx.athanor_id)

      assert Jason.decode!(record.preview) == %{
               "home" => home,
               "athanor" => athanor.name,
               "operation" => "pairing.remove"
             }
    end

    test "cannot reach a client that is not the person's", %{session_ctx: session_ctx} do
      assert {:error, {:not_found, "paired client", "pcl_nobody"}} =
               Pairing.remove(session_ctx, "pcl_nobody")
    end

    # A passkey is shared by every browser that syncs it: removing it here
    # signs it out, and signing in with it again brings it back.
    test "signs a passkey out, revoked, never removed", %{
      account: account,
      device: device,
      session_ctx: session_ctx
    } do
      {pub, _priv} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, passkey} =
        Arca.PairedClients.record_passkey(Context.actor(session_ctx), %{
          user_id: device.user.id,
          kid: Prima.Identity.Key.kid(pub),
          head: DirectoryServer.head(account)
        })

      assert {:ok, %{standing: "revoked"}} = remove!(session_ctx, passkey.id)

      assert standings(device.user.id) == [
               {device.client_id, "device_cert", "active"},
               {passkey.id, "passkey", "revoked"}
             ]
    end
  end

  describe "a device removed here" do
    # The person's outcome: a device they removed does not come back at its
    # next unlock, its hello's answer refused here until they allow it
    # again, and then its next hello pairs it as a new client.
    # Each change is confirmed by another device of the same account, so
    # the person stays the one the device's own hello names.
    test "is refused removed_here at its next hello, and pairs anew once allowed again", %{
      account: account,
      dir: dir,
      device: device,
      session_ctx: session_ctx
    } do
      account = DirectoryServer.add_device!(dir.dir, account)
      other = Devices.admitted!(account, List.last(account.devices))

      assert {:ok, %{standing: "removed"}} =
               device_confirmed!(session_ctx, other, &Pairing.remove(&1, device.client_id))

      {client_id, request} = Devices.hello!(account, device.key)

      assert {:error, :removed_here} =
               Sanctum.DeviceUnlock.admit(client_id, Devices.answer(request, device.key))

      assert standings(device.user.id) == [
               {device.client_id, "device_cert", "removed"},
               {other.client_id, "device_cert", "active"}
             ]

      assert {:ok, %{id: id, standing: "revoked"}} =
               device_confirmed!(session_ctx, other, &Pairing.allow_again(&1, device.client_id))

      assert id == device.client_id

      again = Devices.admitted!(account, device.key)
      assert again.client_id not in [device.client_id, other.client_id]

      assert standings(device.user.id) == [
               {device.client_id, "device_cert", "revoked"},
               {other.client_id, "device_cert", "active"},
               {again.client_id, "device_cert", "active"}
             ]
    end

    test "is listed as removed beside the active ones", %{
      account: account,
      dir: dir,
      device: device,
      session_ctx: session_ctx
    } do
      account = DirectoryServer.add_device!(dir.dir, account)
      other = Devices.admitted!(account, List.last(account.devices))
      {:ok, _removed} = remove!(session_ctx, device.client_id)

      assert {:ok, listed} = Pairing.list(session_ctx)

      assert Enum.map(listed, &{&1.client_id, &1.standing, is_nil(&1.certificate_expires_at)}) ==
               [{device.client_id, "removed", true}, {other.client_id, "active", false}]
    end

    test "is allowed again only under a fresh confirmation, and only while removed", %{
      device: device,
      session_ctx: session_ctx
    } do
      assert {:error, {:not_found, "removed device", id}} =
               Pairing.allow_again(session_ctx, device.client_id)

      assert id == device.client_id

      {:ok, _removed} = remove!(session_ctx, device.client_id)

      assert {:error, {:confirmation_required, %{id: confirmation}}} =
               Pairing.allow_again(session_ctx, device.client_id)

      {:ok, record} =
        Arca.PendingConfirmations.get(
          Context.actor(session_ctx),
          Prima.Confirmation.ref(confirmation)
        )

      {:ok, home} = Prima.Identity.Encoding.canonical_home(Sanctum.origin())
      {:ok, athanor} = Sanctum.Tenancy.Athanors.get(session_ctx.athanor_id)

      assert Jason.decode!(record.preview) == %{
               "home" => home,
               "athanor" => athanor.name,
               "operation" => "pairing.allow_again",
               "resource" => "Test device"
             }

      assert standings(device.user.id) == [{device.client_id, "device_cert", "removed"}]
    end
  end

  describe "list/1" do
    test "the person's active clients in the athanor, marking the one asking", %{
      device: device
    } do
      ctx = Devices.connected!(device)

      assert {:ok, [listed]} = Pairing.list(ctx)
      assert listed.client_id == device.client_id
      assert listed.source == "device_cert"
      assert listed.current
      assert listed.certificate_expires_at
    end
  end
end
