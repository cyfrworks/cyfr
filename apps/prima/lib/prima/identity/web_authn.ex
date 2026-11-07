# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Identity.WebAuthn do
  @moduledoc """
  A passkey's signature: the raw bytes a WebAuthn assertion returned,
  `{"authenticator_data", "client_data", "signature"}`, each unpadded
  base64url, and the one check every verifier makes of it
  (`verify/5`): the identity log's entries (`Prima.Identity`), registry
  requests (`Prima.RegistryRequest`) and sign-in answers (`Prima.SignIn`).

  The check, in this order, the first failure answering:

    1. `client_data` is a JSON object whose `type` is `webauthn.get`
       (`:wrong_type`), whose `challenge` is the base64url of the expected
       challenge bytes (`:wrong_challenge`) and whose `origin` is the
       directory's origin (`:wrong_origin`); a `crossOrigin` of `true` is
       refused (`:cross_origin`) and any other member is accepted, as the
       standard allows. Anything else is `:malformed`.
    2. `authenticator_data` holds at least its 37 fixed bytes
       (`:malformed`), its `rpIdHash` is SHA-256 of the directory's host
       (`:wrong_rp`), and its flags carry user presence
       (`:user_not_present`) and user verification (`:user_not_verified`):
       every passkey ceremony runs with `userVerification: "required"`.
    3. `signature`, a DER-encoded ECDSA P-256 signature, verifies over
       `authenticator_data ‖ SHA-256(client_data)` under the key's 65-byte
       point (`:bad_signature`).
  """

  alias Prima.Identity.Encoding

  @fields ~w(authenticator_data client_data signature)
  @max_bytes 16_384
  @fixed_bytes 37
  @user_present 0x01
  @user_verified 0x04

  @type t :: %{authenticator_data: binary(), client_data: binary(), signature: binary()}

  @type reason ::
          :malformed
          | :wrong_type
          | :wrong_challenge
          | :wrong_origin
          | :cross_origin
          | :wrong_rp
          | :user_not_present
          | :user_not_verified
          | :bad_signature

  @doc "Read an assertion's JSON map: exactly its three members, each non-empty base64url."
  @spec decode(term()) :: {:ok, t()} | :error
  def decode(map) when is_map(map) and not is_struct(map) do
    with :ok <- Encoding.fields(map, @fields, []),
         {:ok, authenticator_data} <- Encoding.unb64(map["authenticator_data"], 1, @max_bytes),
         {:ok, client_data} <- Encoding.unb64(map["client_data"], 1, @max_bytes),
         {:ok, signature} <- Encoding.unb64(map["signature"], 1, @max_bytes) do
      {:ok,
       %{authenticator_data: authenticator_data, client_data: client_data, signature: signature}}
    else
      _ -> :error
    end
  end

  def decode(_value), do: :error

  @doc "The JSON map of an assertion."
  @spec encode(t()) :: map()
  def encode(%{authenticator_data: authenticator_data, client_data: client_data, signature: sig}) do
    %{
      "authenticator_data" => Encoding.b64(authenticator_data),
      "client_data" => Encoding.b64(client_data),
      "signature" => Encoding.b64(sig)
    }
  end

  @doc """
  Check an assertion made by the passkey whose point is `pub` over
  `challenge` (raw bytes), at the directory whose origin and host are
  `origin` and `rp_id`. Refusals in the moduledoc's order.
  """
  @spec verify(t(), binary(), binary(), String.t(), String.t()) :: :ok | {:error, reason()}
  def verify(assertion, pub, challenge, origin, rp_id) do
    with {:ok, client} <- client_data(assertion.client_data),
         :ok <- same(client["type"], "webauthn.get", :wrong_type),
         :ok <- same(client["challenge"], Encoding.b64(challenge), :wrong_challenge),
         :ok <- same(client["origin"], origin, :wrong_origin),
         :ok <- same_origin(client),
         {:ok, rp_id_hash, flags} <- authenticator_data(assertion.authenticator_data),
         :ok <- same(rp_id_hash, :crypto.hash(:sha256, rp_id), :wrong_rp),
         :ok <- flag(flags, @user_present, :user_not_present),
         :ok <- flag(flags, @user_verified, :user_not_verified) do
      signed(assertion, pub)
    end
  end

  defp client_data(bytes) do
    case Prima.Json.decode(bytes) do
      {:ok, %{} = client} -> {:ok, client}
      _ -> {:error, :malformed}
    end
  end

  defp same_origin(%{"crossOrigin" => true}), do: {:error, :cross_origin}
  defp same_origin(_client), do: :ok

  defp authenticator_data(<<rp_id_hash::binary-size(32), flags, _rest::binary>> = bytes)
       when byte_size(bytes) >= @fixed_bytes,
       do: {:ok, rp_id_hash, flags}

  defp authenticator_data(_bytes), do: {:error, :malformed}

  defp flag(flags, bit, reason) do
    if Bitwise.band(flags, bit) == bit, do: :ok, else: {:error, reason}
  end

  defp same(value, value, _reason) when is_binary(value), do: :ok
  defp same(_value, _expected, reason), do: {:error, reason}

  # :crypto raises on a point off the curve or a signature that is not
  # DER; either is a signature that does not verify.
  defp signed(assertion, pub) do
    message = assertion.authenticator_data <> :crypto.hash(:sha256, assertion.client_data)

    if :crypto.verify(:ecdsa, :sha256, message, assertion.signature, [pub, :secp256r1]),
      do: :ok,
      else: {:error, :bad_signature}
  rescue
    _ -> {:error, :bad_signature}
  end
end
