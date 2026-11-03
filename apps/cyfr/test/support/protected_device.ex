# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.ProtectedDevice do
  @moduledoc """
  A protected device through its public entries (`Sanctum.DeviceUnlock`):
  its key, enrolled at setup under a setup token the calling test
  configured, its channel's context minted from a connect proof, and an
  unlock's ticket.
  """

  alias Prima.DeviceCert.{Challenge, Proof}

  @doc "A fresh Ed25519 device key pair."
  def key, do: :crypto.generate_key(:eddsa, :ed25519)

  @doc "Unpadded base64url."
  def b64(bytes), do: Base.url_encode64(bytes, padding: false)

  @doc "A proof's JSON map over `challenge` by `private`."
  def signed(challenge, private), do: Proof.encode(Proof.sign(challenge, private))

  @doc "What the device reports with its key when it asks to enroll."
  def reported({public, _private}, request_id, admission \\ "setup") do
    %{
      "admission" => admission,
      "device_key" => b64(public),
      "request_id" => request_id,
      "holder_kind" => "chip",
      "display_name" => "Kitchen box"
    }
  end

  @doc """
  The installation's first person, enrolled with a new device key under
  `token`: the answer, the key and the identity the person took.
  """
  def enrolled!(token) do
    key = key()
    identity = Sanctum.Test.Newcomers.identity()

    {:ok, %{challenge: challenge}} =
      Sanctum.DeviceUnlock.enrollment_challenge(
        {:setup, token},
        reported(key, identity.request_id)
      )

    {:ok, answer} =
      Sanctum.DeviceUnlock.enroll({:setup, token}, %{
        "proof" => signed(challenge, elem(key, 1)),
        "name" => identity.name,
        "recovery_secret" => b64(identity.recovery_secret)
      })

    Map.merge(answer, %{key: key, identity: identity})
  end

  @doc "The device's channel context, as it is minted from a connect proof."
  def connected!(%{certificate: certificate, key: {_public, private}}) do
    {:ok, challenge} =
      Challenge.new(
        purpose: :connect,
        home: certificate.audience,
        athanor: certificate.athanor,
        client_id: certificate.client_id,
        device_key: certificate.device_key,
        nonce: :crypto.strong_rand_bytes(32),
        now: System.system_time(:millisecond)
      )

    {:ok, ctx} =
      Sanctum.DeviceCerts.verify_connect(
        %{client_id: certificate.client_id, certificate: certificate, source: "198.51.100.40"},
        Proof.sign(challenge, private),
        challenge
      )

    ctx
  end

  @doc "An unlock's answer: the ticket, the session it reserved and its deadline."
  def unlocked!(ctx, {_public, private}) do
    {:ok, %{challenge: challenge}} = Sanctum.DeviceUnlock.unlock(ctx, %{})
    {:ok, answer} = Sanctum.DeviceUnlock.unlock(ctx, %{"proof" => signed(challenge, private)})
    answer
  end
end
