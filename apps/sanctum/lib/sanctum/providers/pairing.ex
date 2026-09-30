# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Pairing do
  @moduledoc """
  The `pairing` tool: a person's paired clients in the athanor in focus —
  begin a pairing, which issues a short-lived bearer invitation after a
  fresh confirmation (`device_pairing`); complete it from the new glass;
  renew a paired client's certificate; revoke one (`pairing_revocation`);
  and list them.

  `complete` is `auth: :anonymous`, as `session.login` is: the glass that
  sends it holds neither a session nor a certificate, so the single-use
  invitation carries the person and athanor, and a session cookie the
  browser still holds never chooses the person. Every other action is a
  person's, through an interactive surface (`consent: :interactive`).

  The invitation's secret is the field `invitation_secret`, which the
  redaction vocabulary (`Prima.Sanitizer`) keeps out of every log.

  Every action answers `{:error, :not_built}`: none is built yet.
  """

  alias Prima.{Arg, Operation}
  alias Sanctum.Context

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    Operation.tool(
      [
        Operation.new("pairing", "begin", "Begin pairing a device", [],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "pairing",
          "complete",
          "Complete pairing from the new device",
          [
            Arg.new("invitation_secret", :string,
              required: true,
              description: "complete: the invitation's secret, from the pairing code's fragment"
            ),
            Arg.new("device_key", :string,
              required: true,
              description: "The device's public key, unpadded base64url (complete, renew)"
            ),
            proof(
              "complete: the device key's signature over the pair challenge; absent, the answer is the challenge to sign",
              false
            )
          ],
          auth: :anonymous,
          kind: :write,
          planes: [:external]
        ),
        Operation.new(
          "pairing",
          "renew",
          "Renew a paired device's certificate",
          [
            client_id(),
            Arg.new("device_key", :string,
              required: true,
              description: "The device's public key, unpadded base64url (complete, renew)"
            ),
            proof("renew: the device key's signature over the renew challenge", true)
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new("pairing", "revoke", "Revoke a paired device", [client_id()],
          kind: :destructive,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new("pairing", "list", "List paired devices", [],
          kind: :read,
          planes: [:external],
          consent: :interactive
        )
      ],
      description:
        "Your paired devices in the athanor in focus: begin pairing a new device, which shows a code the device completes with; renew or revoke a paired device; list them.",
      title: "Paired Devices"
    )
  end

  defp client_id,
    do:
      Arg.new("client_id", :string,
        required: true,
        description: "The paired client (pcl_…) (renew, revoke)"
      )

  # A `Prima.DeviceCert.Proof` as JSON: the challenge's fields and the
  # device key's signature over them.
  defp proof(description, required) do
    Arg.new(
      "proof",
      {:record,
       [
         Arg.new("protocol", :string, required: true),
         Arg.new("purpose", :string, required: true, enum: ["connect", "renew", "pair"]),
         Arg.new("home", :string, required: true),
         Arg.new("athanor", :string, required: true),
         Arg.new("client_id", :string, required: true),
         Arg.new("device_key", :string, required: true),
         Arg.new("nonce", :string, required: true),
         Arg.new("expires_at", :integer, required: true),
         Arg.new("sig", :string, required: true)
       ]},
      required: required,
      description: description
    )
  end

  @actions ~w(begin complete renew revoke list)

  def handle(%Context{}, %{"action" => action}) when action in @actions, do: {:error, :not_built}
  def handle(_ctx, %{"action" => action}), do: {:error, {:unknown_action, "pairing.#{action}"}}
  def handle(_ctx, _args), do: {:error, :action_missing}
end
