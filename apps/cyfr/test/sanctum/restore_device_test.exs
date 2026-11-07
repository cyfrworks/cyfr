# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.RestoreDeviceTest do
  @moduledoc """
  A declared restore (`Arca.SecurityTransitions.restore/1`) and a device
  of an account: the restore suspends this CYFR's paired client and
  revokes its certificate, so the device connects under neither, and it
  touches no key of the account, whose log at its directory and whose
  head cached here stand as they were. The device comes back by a fresh
  hello (`Sanctum.DeviceUnlock`), as a new client with a new certificate,
  and the suspended client stays suspended.
  """

  use PrismWeb.ConnCase, async: false

  import Cyfr.Test.ProtectedDevice

  alias Sanctum.Test.{DirectoryServer, Devices}

  @token String.duplicate("5c", 32)
  @source "198.51.100.71"

  setup do
    Arca.Cache.init()
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Arca.Repo.delete_all(Arca.Schemas.User)
    %{device: enrolled!(@token)}
  end

  defp restored! do
    {:ok, restore_id} = Arca.SecurityTransitions.mark_restore(Prima.Actor.system())
    {:ok, %{restore_id: ^restore_id}} = Arca.SecurityTransitions.restore(slot: :none)
    :ok
  end

  defp connect(%{certificate: certificate, key: {_pub, priv}} = device) do
    challenge = Devices.challenge(device)

    Sanctum.DeviceCerts.verify_connect(
      %{client_id: certificate.client_id, certificate: certificate, source: @source},
      Prima.DeviceCert.Proof.sign(challenge, priv),
      challenge
    )
  end

  defp client(client_id), do: Arca.Repo.get!(Arca.Schemas.PairedClient, client_id)

  defp certificates(client_id) do
    import Ecto.Query, only: [from: 2]

    Arca.Repo.all(
      from(c in Arca.Schemas.DeviceCertificate, where: c.paired_client_id == ^client_id)
    )
  end

  test "suspends the device's client and certificate and no key of its account", %{
    device: device
  } do
    %{account: account, dir: dir} = device
    assert {:ok, _ctx} = connect(device)
    log = DirectoryServer.log(dir.dir, account.identifier)
    {:ok, cached} = Arca.DirectoryHeads.get(Prima.Actor.system(), account.identifier)

    :ok = restored!()

    assert client(device.client_id).standing == "suspended"
    assert [%{state: "revoked"}] = certificates(device.client_id)
    assert {:error, _refused} = connect(device)

    # The account is the person's, never this CYFR's: its log at the
    # directory and the head this CYFR caches are as they were, the device
    # key listed among them.
    assert DirectoryServer.log(dir.dir, account.identifier) == log

    assert {:ok, after_restore} =
             Arca.DirectoryHeads.get(Prima.Actor.system(), account.identifier)

    assert after_restore.head_hash == cached.head_hash
    assert after_restore.state == cached.state
  end

  test "the device comes back by a fresh hello, as a new client", %{device: device} do
    :ok = restored!()

    again = Devices.admitted!(device.account, device.key)

    refute again.client_id == device.client_id
    assert again.certificate.kid == device.certificate.kid
    assert {:ok, %Sanctum.Context{client_id: client_id}} = connect(again)
    assert client_id == again.client_id

    # The client the restore suspended stays suspended, and its old
    # certificate still connects nothing.
    assert client(device.client_id).standing == "suspended"
    assert {:error, _refused} = connect(device)
  end
end
