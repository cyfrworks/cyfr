# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.ProtectedDevice do
  @moduledoc """
  A protected device through its public entries (`Sanctum.DeviceUnlock`):
  a device key of an account at a scripted directory, admitted by its
  hello under a setup token the calling test configured, its channel's
  context minted from a connect proof, and an unlock's ticket.
  """

  alias Prima.DeviceCert.Proof
  alias Sanctum.Test.{Devices, DirectoryServer}

  @doc "Unpadded base64url."
  def b64(bytes), do: Base.url_encode64(bytes, padding: false)

  @doc "A proof's JSON map over `challenge` by `private`."
  def signed(challenge, private), do: Proof.encode(Proof.sign(challenge, private))

  @doc """
  The installation's first person, an account at a scripted directory
  started for the calling test, whose device key is admitted by its hello
  under `token`: what the admission answers (`client_id`, `certificate`,
  `standing`), the device `key`, the person (`user`), the `account` and
  its directory (`dir`, `Sanctum.Test.DirectoryServer.start!/2`'s).
  """
  def enrolled!(token) do
    tls = DirectoryServer.tls()
    DirectoryServer.listen!()
    DirectoryServer.seam!(tls)
    dir = DirectoryServer.start!(tls)
    Prima.Test.Env.put_app_env(:sanctum, :directory_url, dir.url)
    account = DirectoryServer.account!(dir.dir, dir.url)

    account
    |> Devices.admitted!(List.last(account.devices), {:setup, token})
    |> Map.merge(%{account: account, dir: dir})
  end

  @doc "The device's channel context, as it is minted from a connect proof."
  def connected!(device), do: Devices.connected!(device)

  @doc "An unlock's answer: the ticket, the session it reserved and its deadline."
  def unlocked!(ctx, {_public, private}) do
    {:ok, %{challenge: challenge}} = Sanctum.DeviceUnlock.unlock(ctx, %{})
    {:ok, answer} = Sanctum.DeviceUnlock.unlock(ctx, %{"proof" => signed(challenge, private)})
    answer
  end
end
