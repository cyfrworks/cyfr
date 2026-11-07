# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DeviceHelloTest do
  @moduledoc """
  A device of an account comes here by its hello (`Sanctum.DeviceUnlock`):
  the CYFR answers a `sign_in` request bound to the channel and held for
  the hello's key, the device signs it, and the answer, verified against
  the account's log at a scripted directory, admits the person under the
  setup token, an invitation or the door, and pairs the device with its
  first certificate under this CYFR's installation key
  (`Sanctum.DeviceCerts`). A capability that admits nobody writes
  nothing; a hello asked again pairs nothing twice. The certificate then
  connects, a renewal issues under the head this CYFR holds, and a
  refresh whose walk removes the key or recovers the account retires the
  device.
  """

  # The directory seam, the setup token, the public URL, the directory
  # setting and the access mode are process-wide.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{DirectoryHead, PairedClient, User}
  alias Prima.DeviceCert
  alias Prima.DeviceCert.Proof
  alias Prima.Identity.Key
  alias Sanctum.{DeviceCerts, DeviceUnlock}
  alias Sanctum.Test.{DirectoryServer, Devices}

  @token String.duplicate("5e", 32)
  @origin "https://cyfr.example"

  setup_all do
    %{tls: DirectoryServer.tls()}
  end

  setup %{tls: tls} = tags do
    Arca.Test.Sandbox.setup!(tags)
    Prima.Test.RateLimiter.reset!()
    DirectoryServer.listen!()
    DirectoryServer.seam!(tls)
    dir = DirectoryServer.start!(tls)

    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Prima.Test.Env.put_app_env(:sanctum, :public_url, @origin)
    Prima.Test.Env.put_app_env(:sanctum, :directory_url, dir.url)
    Prima.Test.Env.put_app_env(:sanctum, :access_mode, :public)

    # The installation holds no person inside this test's transaction.
    Arca.Repo.delete_all(User)

    %{dir: dir, account: DirectoryServer.account!(dir.dir, dir.url)}
  end

  defp device(account), do: List.last(account.devices)

  defp clients(user_id),
    do: Arca.Repo.all(from(c in PairedClient, where: c.user_id == ^user_id))

  defp aged!(identifier) do
    {1, _} =
      Arca.Repo.update_all(from(h in DirectoryHead, where: h.identifier == ^identifier),
        set: [verified_at: DateTime.add(Arca.ServerMetaStorage.now!(), -3_600, :second)]
      )

    :ok
  end

  describe "the hello" do
    test "under the setup token admits the first person and pairs the device with its certificate",
         %{account: account} do
      admitted = Devices.admitted!(account, device(account), {:setup, @token})
      {pub, _priv} = admitted.key

      assert admitted.user.admission == "setup"
      assert admitted.user.platform_admin_at

      assert %DeviceCert{} = certificate = admitted.certificate
      assert certificate.kid == Key.kid(pub)
      assert certificate.client_id == admitted.client_id
      assert certificate.identifier == account.identifier
      assert certificate.head == DirectoryServer.head(account)
      assert certificate.audience == @origin

      assert admitted.standing == %{
               client_id: admitted.client_id,
               athanor: certificate.athanor,
               expires_at: certificate.expires_at
             }

      # Signed by this CYFR's installation key, and by nothing else.
      {installation, _private} = Sanctum.Cipher.installation_key()

      assert {:ok, _} =
               DeviceCert.verify(certificate, installation,
                 home: @origin,
                 head: certificate.head,
                 now: System.system_time(:millisecond),
                 skew: 0
               )

      assert [
               %{
                 kid: kid,
                 device_public_key: ^pub,
                 standing: "active",
                 holder_kind: "software",
                 display_name: "Test device"
               }
             ] = clients(admitted.user.id)

      assert kid == certificate.kid
    end

    test "the holder and name a hello reports reach the paired client, in the hello's grammar",
         %{account: account} do
      hello = Devices.hello(account, device(account), {:setup, @token})
      client_id = Prima.UUID7.generate_id("pcl")

      for {field, value} <- [
            holder_kind: "platform",
            holder_kind: nil,
            display_name: "",
            display_name: "a\nb",
            display_name: String.duplicate("é", 33)
          ] do
        assert {:error, {:invalid_argument, _sentence}} =
                 DeviceUnlock.hello(client_id, Map.put(hello, field, value)),
               inspect({field, value})
      end

      # 64 bytes in 32 characters is a name; the row keeps it as reported.
      name = String.duplicate("é", 32)

      admitted =
        Devices.admitted!(account, device(account), {:setup, @token}, %{
          holder_kind: "chip",
          display_name: name
        })

      assert [%{holder_kind: "chip", display_name: ^name}] = clients(admitted.user.id)
    end

    test "a capability that admits nobody refuses before anything is held or written", %{
      account: account
    } do
      hello = Devices.hello(account, device(account))
      client_id = Prima.UUID7.generate_id("pcl")

      assert {:error, :setup_closed} =
               DeviceUnlock.hello(client_id, Map.put(hello, :admission, {:setup, "not-it"}))

      assert {:error, :invitation_invalid} =
               DeviceUnlock.hello(client_id, Map.put(hello, :admission, {:invitation, "nope"}))

      # The open admission without the door's * admits nobody: nothing is
      # written for the answer either.
      {client_id, request} = Devices.hello!(account, device(account))

      assert {:error, {:door, :not_allowed}} =
               DeviceUnlock.admit(client_id, Devices.answer(request, device(account)))

      assert Arca.Repo.all(User) == []
      assert Arca.Repo.all(PairedClient) == []
    end

    test "a hello asked again answers the same client with a new certificate", %{
      account: account
    } do
      first = Devices.admitted!(account, device(account), {:setup, @token})
      again = Devices.admitted!(account, device(account))

      assert again.client_id == first.client_id
      assert again.certificate != first.certificate
      assert [_one] = clients(first.user.id)
    end

    test "is answered only by the key it named, once", %{dir: dir, account: account} do
      account = DirectoryServer.add_device!(dir.dir, account)
      [named, other] = account.devices
      {client_id, request} = Devices.hello!(account, named, {:setup, @token})

      # Another key of the account signs it: refused, and the request spent.
      assert {:error, :answer_refused} =
               DeviceUnlock.admit(client_id, Devices.answer(request, other))

      assert {:error, :answer_refused} =
               DeviceUnlock.admit(client_id, Devices.answer(request, named))

      assert Arca.Repo.all(PairedClient) == []

      # An answer on another channel than the one that asked is no answer.
      {_client_id, request} = Devices.hello!(account, named, {:setup, @token})

      assert {:error, :answer_refused} =
               DeviceUnlock.admit(
                 Prima.UUID7.generate_id("pcl"),
                 Devices.answer(request, named)
               )
    end
  end

  describe "the certificate" do
    setup %{account: account} do
      %{admitted: Devices.admitted!(account, device(account), {:setup, @token})}
    end

    test "connects the device, and each request stands on it", %{admitted: admitted} do
      ctx = Devices.connected!(admitted)

      assert ctx.auth_method == :device
      assert ctx.client_id == admitted.client_id
      assert ctx.user_id == admitted.user.id
      assert ctx.credential_binding.kid == admitted.certificate.kid
      assert ctx.credential_binding.head == admitted.certificate.head

      assert {:ok, _ctx} = DeviceCerts.verify_request(admitted.certificate, ctx)
    end

    test "one this CYFR never recorded is refused, whoever signed it", %{admitted: admitted} do
      ctx = Devices.connected!(admitted)
      forged = %{admitted.certificate | not_before: admitted.certificate.not_before - 1_000}
      {_public, private} = Sanctum.Cipher.installation_key()

      assert {:error, :bad_signature} =
               DeviceCerts.verify_request(DeviceCert.sign(forged, private), ctx)
    end

    test "a connect proof by another key is refused", %{admitted: admitted} do
      {_pub, other} = :crypto.generate_key(:eddsa, :ed25519)
      challenge = Devices.challenge(admitted)

      assert {:error, :proof_refused} =
               DeviceCerts.verify_connect(
                 %{client_id: admitted.client_id, certificate: admitted.certificate},
                 Proof.sign(challenge, other),
                 challenge
               )
    end

    test "a renewal issues a new certificate under the head this CYFR holds now", %{
      dir: dir,
      account: account,
      admitted: admitted
    } do
      account = DirectoryServer.add_device!(dir.dir, account)
      aged!(account.identifier)
      assert {:ok, _head} = Sanctum.IdentityFreshness.fresh?(account.identifier)

      {pub, priv} = admitted.key
      challenge = Devices.challenge(admitted, :renew)
      proof = Proof.sign(challenge, priv)

      {:ok, renewal} =
        DeviceCerts.verify_connect(
          %{client_id: admitted.client_id, certificate: admitted.certificate},
          proof,
          challenge
        )

      assert {:ok, %{certificate: renewed}} =
               Sanctum.Pairing.renew(renewal, %{
                 client_id: admitted.client_id,
                 device_key: pub,
                 proof: Proof.encode(proof)
               })

      assert renewed.head == DirectoryServer.head(account)
      assert renewed.head != admitted.certificate.head
      assert {:ok, _ctx} = DeviceCerts.verify_request(renewed, renewal)
    end

    test "a refresh that removes the device's key retires it", %{
      dir: dir,
      account: account,
      admitted: admitted
    } do
      ctx = Devices.connected!(admitted)
      {pub, _priv} = admitted.key

      DirectoryServer.remove_key!(dir.dir, account, Key.kid(pub))
      aged!(account.identifier)

      assert {:error, :revoked} = DeviceCerts.verify_request(admitted.certificate, ctx)
    end

    test "a refresh that reads a recovery retires it", %{
      dir: dir,
      account: account,
      admitted: admitted
    } do
      ctx = Devices.connected!(admitted)

      DirectoryServer.recover!(dir.dir, account)
      aged!(account.identifier)

      assert {:error, :revoked} = DeviceCerts.verify_request(admitted.certificate, ctx)
    end
  end
end
