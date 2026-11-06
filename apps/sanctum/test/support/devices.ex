# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Test.Devices do
  @moduledoc """
  A device of an account admitted here by its hello, through
  `Sanctum.DeviceUnlock`'s public entries, against the scripted directory
  (`Sanctum.Test.DirectoryServer`), whose seam the calling test set; and
  its channel's context, as a connect proof establishes it
  (`Sanctum.DeviceCerts.verify_connect/3`).
  """

  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.Identity.Key
  alias Prima.SignIn.DeviceAnswer

  @doc """
  The request the hello of `device` (a key pair of `account`'s) is
  answered, on a channel that reserved a new client id: `{client_id,
  request}`. `admission` is the hello's (`{:setup, token}`,
  `{:invitation, code}` or nil).
  """
  def hello!(account, {pub, _priv}, admission \\ nil) do
    client_id = Prima.UUID7.generate_id("pcl")

    {:ok, request} =
      Sanctum.DeviceUnlock.hello(client_id, %{
        kid: Key.kid(pub),
        identifier: account.identifier,
        admission: admission
      })

    {client_id, request}
  end

  @doc "`device`'s answer to `request`, signed after its unlock."
  def answer(request, {pub, priv}), do: DeviceAnswer.sign(request, Key.kid(pub), priv)

  @doc """
  `device` of `account` admitted by its hello under `admission`: what
  `Sanctum.DeviceUnlock.admit/2` answers, with the key and the person.
  """
  def admitted!(account, device, admission \\ nil) do
    {client_id, request} = hello!(account, device, admission)
    {:ok, admitted} = Sanctum.DeviceUnlock.admit(client_id, answer(request, device))
    {:ok, user} = Sanctum.Tenancy.Users.get_by_identifier(account.identifier)
    Map.merge(admitted, %{key: device, user: user})
  end

  @doc "The `connect` (or `renew`) challenge a channel issues for `admitted`."
  def challenge(%{certificate: certificate, key: {pub, _priv}}, purpose \\ :connect) do
    {:ok, challenge} =
      Challenge.new(
        purpose: purpose,
        home: certificate.audience,
        athanor: certificate.athanor,
        client_id: certificate.client_id,
        device_key: pub,
        nonce: :crypto.strong_rand_bytes(32),
        now: System.system_time(:millisecond)
      )

    challenge
  end

  @doc "The device's channel context, as a connect proof establishes it."
  def connected!(%{certificate: certificate, key: {_pub, priv}} = admitted) do
    challenge = challenge(admitted)

    {:ok, ctx} =
      Sanctum.DeviceCerts.verify_connect(
        %{client_id: certificate.client_id, certificate: certificate, source: "198.51.100.40"},
        Proof.sign(challenge, priv),
        challenge
      )

    ctx
  end
end
