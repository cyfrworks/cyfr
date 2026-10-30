# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.RecoveryCode do
  @moduledoc """
  A person's recovery code, the one line they keep: `CYFR-` and 112
  Crockford base32 symbols (`Prima.Crockford`) in 14 groups of 8 joined by
  `-`, 130 characters, uppercase. The symbols spell 70 bytes: the 32-byte
  digest of the person's identifier (the 64 hex digits after `per_`), the
  32-byte recovery secret, and a 6-byte check, the first 6 bytes of
  SHA-256 over `"cyfr-recovery-code/v1"`, a zero byte, the digest and the
  secret.

  `encode/2` composes the canonical text; the server composes every code
  a page shows. `decode/1` reads a code as a person copied it, the same
  way the browser's reader does
  (`apps/cyfr/assets/js/system_layer/recovery_code.js`); both are held to
  `tests/fixtures/recovery_code.json`. Reading:

  1. Every space, tab, line feed, carriage return and hyphen-minus is
     removed, wherever it is.
  2. Anything left outside ASCII is `:not_a_code`.
  3. ASCII `a` to `z` are mapped to uppercase; nothing else is.
  4. The first four characters are `CYFR`, else `:not_a_code`.
  5. `O` reads as `0`, and `I` and `L` as `1`, as Crockford base32 does.
  6. Exactly 112 symbols of the alphabet follow, else `:not_a_code`.
  7. The check matches, else `:typo`.
  """

  alias Prima.Crockford
  alias Prima.Identity.Encoding

  @protocol "cyfr-recovery-code/v1"
  @prefix "CYFR"
  @digest_bytes 32
  @secret_bytes 32
  @check_bytes 6
  @group 8
  @ignored [" ", "\t", "\n", "\r", "-"]

  @type reason :: :not_a_code | :typo

  @doc "The domain string the check is computed under."
  @spec protocol() :: String.t()
  def protocol, do: @protocol

  @doc """
  The canonical text of the code for `identifier` (`per_` and 64 lowercase
  hex digits) and the 32-byte `secret`. Anything else raises.
  """
  @spec encode(String.t(), <<_::256>>) :: String.t()
  def encode(identifier, <<secret::binary-size(@secret_bytes)>>) do
    if not Encoding.identifier?(identifier), do: raise(ArgumentError, "not a person identifier")

    "per_" <> hex = identifier
    digest = Base.decode16!(hex, case: :lower)
    symbols = Crockford.encode(digest <> secret <> check(digest, secret))
    groups = for <<group::binary-size(@group) <- symbols>>, do: group
    Enum.join([@prefix | groups], "-")
  end

  @doc """
  The identifier and the 32-byte secret `text` spells, read as the
  module documentation says, or why it does not.
  """
  @spec decode(term()) ::
          {:ok, %{identifier: String.t(), secret: <<_::256>>}} | {:error, reason()}
  def decode(text) when is_binary(text) do
    stripped = String.replace(text, @ignored, "")

    with true <- ascii?(stripped),
         @prefix <> body <- String.upcase(stripped, :ascii),
         {:ok,
          <<digest::binary-size(@digest_bytes), secret::binary-size(@secret_bytes),
            check::binary-size(@check_bytes)>>} <- Crockford.decode(body) do
      if check == check(digest, secret) do
        {:ok, %{identifier: "per_" <> Base.encode16(digest, case: :lower), secret: secret}}
      else
        {:error, :typo}
      end
    else
      _ -> {:error, :not_a_code}
    end
  end

  def decode(_text), do: {:error, :not_a_code}

  defp check(digest, secret) do
    binary_part(:crypto.hash(:sha256, [@protocol, <<0>>, digest, secret]), 0, @check_bytes)
  end

  defp ascii?(<<>>), do: true
  defp ascii?(<<byte, rest::binary>>) when byte < 128, do: ascii?(rest)
  defp ascii?(_bytes), do: false
end
