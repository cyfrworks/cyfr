# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Pairing do
  @moduledoc """
  The `pairing` tool: a person's paired clients in the athanor in focus,
  the devices of their account a hello paired here (`Sanctum.DeviceUnlock`)
  and the passkeys that signed in here: renew a paired device's
  certificate; revoke one (`pairing_revocation`); and list them. Every
  action is a person's, through an interactive surface (`consent:
  :interactive`); a proof is the field `proof`, which the redaction
  vocabulary (`Prima.Sanitizer`) keeps out of every log.

  The decisions are `Sanctum.Pairing`'s. Here each action is read off the
  wire and answered on it:

    * `renew` answers the client's id and its replacement certificate. It
      is reached from the device channel's renewal exchange alone, under
      the renewal context the channel obtains for the client that proved
      its key; any other caller, an ordinary device intent among them, is
      refused.
    * `revoke` answers the client's id and its standing, `revoked`.
    * `list` answers the person's active paired clients, each with what
      holds its key (`holder_kind`) and the name it shows (`display_name`)
      where it reported them, whether its key may sync (`synced`, a passkey's
      platform holder WebAuthn registered backup eligible; the passkey
      revoked wherever it synced) and what it last reported of its disks within the
      last minute (`storage`: `root` and `data`, each `encrypted`,
      `unencrypted` or `unknown`), information a person reads and never
      an input to a decision.
  """

  alias Prima.{Arg, DeviceCert, Operation}
  alias Prima.Identity.Encoding
  alias Sanctum.{Context, Pairing}

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    Operation.tool(
      [
        Operation.new(
          "pairing",
          "renew",
          "Renew a paired device's certificate",
          [
            client_id(),
            Arg.new("device_key", :string,
              required: true,
              description: "renew: the device's public key, unpadded base64url"
            ),
            proof("renew: the device key's signature over the renew challenge", true)
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new("pairing", "revoke", "Revoke a paired device", [client_id()],
          reduces_authority: true,
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
        "Your paired devices in the athanor in focus: renew or revoke a paired device, and list them.",
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
         Arg.new("purpose", :string, required: true, enum: ["renew"]),
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

  def handle(%Context{} = ctx, %{"action" => "renew"} = args) do
    with {:ok, device_key} <- device_key(args["device_key"]),
         {:ok, paired} <-
           Pairing.renew(ctx, %{
             client_id: args["client_id"],
             device_key: device_key,
             proof: args["proof"]
           }) do
      {:ok, completed(paired)}
    else
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "revoke", "client_id" => client_id})
      when is_binary(client_id) do
    case Pairing.revoke(ctx, client_id) do
      {:ok, row} -> {:ok, %{client_id: row.id, standing: row.standing}}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    case Pairing.list(ctx) do
      {:ok, clients} -> {:ok, %{clients: Enum.map(clients, &listed/1)}}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def handle(_ctx, %{"action" => "revoke"}),
    do: {:error, {:invalid_argument, "Missing required argument: client_id"}}

  def handle(_ctx, %{"action" => action}), do: {:error, {:unknown_action, "pairing.#{action}"}}
  def handle(_ctx, _args), do: {:error, :action_missing}

  defp device_key(value) do
    case Encoding.unb64(value, Encoding.key_bytes()) do
      {:ok, device_key} ->
        {:ok, device_key}

      :error ->
        {:error,
         {:invalid_argument, "The device key is not unpadded base64url of a 32-byte public key"}}
    end
  end

  defp completed(%{client_id: client_id, certificate: certificate}),
    do: %{client_id: client_id, certificate: DeviceCert.encode(certificate)}

  defp listed(client) do
    %{
      client_id: client.client_id,
      source: client.source,
      paired_at: Prima.Time.iso8601(client.paired_at),
      certificate_expires_at: Prima.Time.iso8601(client.certificate_expires_at),
      current: client.current,
      holder_kind: client.holder_kind,
      display_name: client.display_name,
      synced: client.synced,
      storage: storage(client.storage)
    }
  end

  defp storage(nil), do: nil
  defp storage(%{root: root, data: data}), do: %{root: to_string(root), data: to_string(data)}

  # The ceremony's own refusals in the one refusal shape every surface
  # renders (`Prima.Refusal`), each with the sentence its person reads; the
  # vocabulary's and the stores' own reasons (a confirmation signal, a
  # rate limit, a standing or tenancy refusal) pass as they are.
  defp refusal(:proof_refused),
    do: refused(:unauthenticated, :proof_refused, "The device's proof of its key was refused")

  defp refusal(:stale_head), do: Prima.Refusal.classify(:stale_head)

  defp refusal(:revoked),
    do: refused(:forbidden, :revoked, "This device's pairing was revoked; pair it again")

  defp refusal(:not_standing),
    do:
      refused(
        :forbidden,
        :not_standing,
        "The person this pairing is for no longer stands in this athanor"
      )

  defp refusal(:renewal_exchange_only),
    do:
      refused(
        :forbidden,
        :renewal_exchange_only,
        "A paired device renews its certificate only through its device channel's renewal exchange"
      )

  defp refusal(:replayed),
    do: refused(:unauthenticated, :replayed, "This renewal proof was already used")

  defp refusal({:rate_limited, retry_after_ms}) when is_integer(retry_after_ms),
    do: {:rate_limited, div(retry_after_ms + 999, 1_000)}

  defp refusal(reason), do: reason

  defp refused(class, reason, message),
    do: %Prima.Refusal{class: class, reason: reason, message: message}
end
