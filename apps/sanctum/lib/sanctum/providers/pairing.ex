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
  redaction vocabulary (`Prima.Sanitizer`) keeps out of every log, in the
  arguments `complete` takes and in the answer `begin` gives; a proof is
  the field `proof`, redacted the same way.

  The ceremony is `Sanctum.Pairing`'s. Here each action is read off the
  wire and answered on it:

    * `begin` answers the invitation's secret (unpadded base64url, for the
      pairing code), the client id it reserves, its expiry, and the
      `invitation_url` a new glass opens: this home's `/pair` page with the
      secret in its fragment's `code`, so the page reads it in the browser
      and no request line carries it. The pairing QR encodes that URL; it
      is built here and nowhere else.
    * `complete` answers the `pair` challenge to sign when it carries no
      proof, and the paired client's id and its first certificate
      (`Prima.DeviceCert`'s JSON) when it carries the proof over it.
    * `renew` answers the client's id and its replacement certificate. It
      is reached from the device channel's renewal exchange alone, under
      the renewal context the channel obtains for the client that proved
      its key; any other caller, an ordinary device intent among them, is
      refused.
    * `revoke` answers the client's id and its standing, `revoked`.
    * `list` answers the person's active paired clients.
  """

  alias Prima.{Arg, DeviceCert, Operation}
  alias Prima.DeviceCert.Challenge
  alias Prima.Identity.Encoding
  alias Sanctum.{Context, Pairing}

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

  def handle(%Context{} = ctx, %{"action" => "begin"} = args) do
    case Pairing.begin(ctx, Map.delete(args, "action")) do
      {:ok, invitation} ->
        {:ok,
         %{
           invitation_secret: Encoding.b64(invitation.invitation_secret),
           invitation_url: invitation_url(invitation.invitation_secret),
           client_id: invitation.client_id,
           expires_at: Prima.Time.iso8601(invitation.expires_at)
         }}

      {:error, reason} ->
        {:error, refusal(reason)}
    end
  end

  # The glass's submission is read as the device protocol reads a
  # `pair_request` (`Prima.Device`), so the secret and the key reach the
  # ceremony as the raw bytes their codecs decode, or not at all.
  def handle(%Context{} = ctx, %{"action" => "complete"} = args) do
    with {:ok, secret, device_key} <- pair_request(args),
         {:ok, proof} <- optional_proof(args),
         {:ok, answer} <- Pairing.complete(ctx, secret, %{device_key: device_key, proof: proof}) do
      {:ok, completed(answer)}
    else
      {:error, reason} -> {:error, refusal(reason)}
    end
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

  defp pair_request(args) do
    message = %{
      "protocol" => Prima.Device.protocol(),
      "type" => "pair_request",
      "invitation_secret" => args["invitation_secret"],
      "device_key" => args["device_key"]
    }

    case Prima.Device.decode(message, :glass) do
      {:ok, {:pair_request, %{invitation_secret: secret, device_key: device_key}}} ->
        {:ok, secret, device_key}

      {:error, _malformed} ->
        {:error,
         {:invalid_argument,
          "The pairing code or the device key is not one a pairing takes: unpadded base64url of " <>
            "16 and 32 bytes"}}
    end
  end

  # The one spelling of the link a pairing code opens: this home's `/pair`
  # page, the secret in the fragment, which a browser never sends.
  defp invitation_url(secret),
    do: Sanctum.Person.home() <> "/pair#code=" <> Encoding.b64(secret)

  defp optional_proof(%{"proof" => proof}) when is_map(proof), do: {:ok, proof}
  defp optional_proof(_args), do: {:ok, nil}

  defp device_key(value) do
    case Encoding.unb64(value, Encoding.key_bytes()) do
      {:ok, device_key} ->
        {:ok, device_key}

      :error ->
        {:error,
         {:invalid_argument, "The device key is not unpadded base64url of a 32-byte public key"}}
    end
  end

  defp completed(%{challenge: challenge}), do: %{challenge: Challenge.encode(challenge)}

  defp completed(%{client_id: client_id, certificate: certificate}),
    do: %{client_id: client_id, certificate: DeviceCert.encode(certificate)}

  defp listed(client) do
    %{
      client_id: client.client_id,
      label: client.label,
      source: client.source,
      paired_at: Prima.Time.iso8601(client.paired_at),
      certificate_expires_at: Prima.Time.iso8601(client.certificate_expires_at),
      current: client.current
    }
  end

  # The ceremony's own refusals in the one refusal shape every surface
  # renders (`Prima.Refusal`), each with the sentence its person reads; the
  # vocabulary's and the stores' own reasons (a confirmation signal, a
  # rate limit, a standing or tenancy refusal) pass as they are.
  defp refusal(:invalid_invitation),
    do:
      refused(
        :unauthenticated,
        :invalid_invitation,
        "This pairing code is not valid: it has expired or was already used. Show a new one."
      )

  defp refusal(:proof_refused),
    do: refused(:unauthenticated, :proof_refused, "The device's proof of its key was refused")

  defp refusal(:wrong_audience),
    do: refused(:invalid_argument, :wrong_audience, "This pairing code is for another home")

  defp refusal(:remote_identity_unavailable),
    do:
      refused(
        :unavailable,
        :remote_identity_unavailable,
        "Pairing a device for a person whose identity is at another home is not built yet."
      )

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

  defp refusal({:invalid, _errors}),
    do: {:invalid_argument, "The pairing could not be recorded as given"}

  defp refusal(reason), do: reason

  defp refused(class, reason, message),
    do: %Prima.Refusal{class: class, reason: reason, message: message}
end
