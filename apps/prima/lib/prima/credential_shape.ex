# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.CredentialShape do
  @moduledoc """
  The shapes of the credentials the platform issues that a value alone
  identifies, and the one place they are defined: the minters draw from
  them (`mint/1`) and `Prima.Sanitizer` recognises them by them
  (`redact/2`), so a credential under an innocent key, or embedded in a
  longer string, is still redacted.

  Every shape is a prefix followed by base64url without padding (the
  alphabet `A-Za-z0-9_-`):

    * `{:api_key, type}` — an API key, `cyfr_pk_` (`:application`),
      `cyfr_sk_` (`:service`) or `cyfr_ak_` (`:admin`) and 24 random bytes
      (`Sanctum.ApiKey`);
    * `:webhook_secret` — a webhook's signing secret, `whsec_` and 24
      random bytes (`Sanctum.Webhook`);
    * `:confirmation_secret` — a pending confirmation's secret, `cnf_` and
      32 random bytes (`Prima.Confirmation`);
    * `:signed_token` — a token signed by `Plug.Crypto.sign/4` with
      SHA-256, which is how the tincture asset, frame and validation
      credentials are spelled (`Sanctum.TinctureAuth`): the header
      `SFMyNTY`, a dot, the payload, a dot and the 43-character signature.
      The header is `plug_crypto`'s, which Prima does not depend on, so it
      is pinned here and every minted credential is tested against it.

  A run is a credential only whole: its random part has exactly the
  shape's length and ends at a boundary, which is the end of the text, a
  character outside the alphabet, or the start of another credential's
  prefix. So a longer malformed run, a wrong alphabet or a short one stays
  readable, while two credentials run together are both redacted, and one
  redaction is a fixpoint: a placeholder begins with a character outside
  the alphabet, so redacting one run never makes another recognisable,
  and the text a sanitizer stores is the text it would store again. Each
  candidate is examined over the fixed length its shape requires and the
  one character after it, and a signed token's payload over at most
  `signed_token_payload_max/0` characters, so recognition is linear in the
  text however many candidates it holds.

  Unprefixed credentials — session tokens, consent proof tokens, sign-in
  tickets, OAuth `state` and `code_verifier`, pairing secrets — are 43
  base64url characters and nothing else. A SHA-256 digest, a content
  address and many identifiers have the same form, so a value-shape rule
  for them would redact ordinary data; they are covered by the
  sanitizer's key names alone.
  """

  @api_key_prefixes %{application: "cyfr_pk_", service: "cyfr_sk_", admin: "cyfr_ak_"}

  # Random bytes drawn after each prefix.
  @api_key_bytes 24
  @webhook_secret_prefix "whsec_"
  @webhook_secret_bytes 24
  @confirmation_secret_prefix "cnf_"
  @confirmation_secret_bytes 32

  # `Plug.Crypto.MessageVerifier`'s protected header for HMAC-SHA-256, and
  # the unpadded base64url length of its 32-byte signature.
  @signed_token_header "SFMyNTY"
  @signed_token_signature_bytes 32

  # The longest payload a signed token is recognised with. The tincture
  # credentials' payloads are a few hundred characters (an asset
  # credential is bounded to 1024 characters whole, as its path carries
  # it), and every one minted is tested against this bound; it is what
  # keeps a candidate's scan, and so recognition, linear in its input.
  @signed_token_payload_max 1024

  @typedoc "A shape a value alone identifies."
  @type kind ::
          {:api_key, :application | :service | :admin}
          | :webhook_secret
          | :confirmation_secret
          | :signed_token

  @doc "The API-key prefix of each key type."
  @spec api_key_prefixes() :: %{atom() => String.t()}
  def api_key_prefixes, do: @api_key_prefixes

  @doc "The prefixed shapes: each kind with its prefix and its random part's length."
  @spec prefixed() :: [{kind(), String.t(), pos_integer()}]
  def prefixed do
    api_keys =
      for {type, prefix} <- Enum.sort(@api_key_prefixes),
          do: {{:api_key, type}, prefix, encoded_length(@api_key_bytes)}

    api_keys ++
      [
        {:webhook_secret, @webhook_secret_prefix, encoded_length(@webhook_secret_bytes)},
        {:confirmation_secret, @confirmation_secret_prefix,
         encoded_length(@confirmation_secret_bytes)}
      ]
  end

  @doc "A signed token's header, the segment before its first dot."
  @spec signed_token_header() :: String.t()
  def signed_token_header, do: @signed_token_header

  @doc "A signed token's signature length, the segment after its last dot."
  @spec signed_token_signature_length() :: pos_integer()
  def signed_token_signature_length, do: encoded_length(@signed_token_signature_bytes)

  @doc "The longest payload, the segment between a signed token's dots, it is recognised with."
  @spec signed_token_payload_max() :: pos_integer()
  def signed_token_payload_max, do: @signed_token_payload_max

  @doc """
  A new credential of a prefixed kind: its prefix and its random bytes,
  base64url without padding.
  """
  @spec mint(kind()) :: String.t()
  def mint({:api_key, type}) when is_map_key(@api_key_prefixes, type),
    do: drawn(Map.fetch!(@api_key_prefixes, type), @api_key_bytes)

  def mint(:webhook_secret), do: drawn(@webhook_secret_prefix, @webhook_secret_bytes)

  def mint(:confirmation_secret),
    do: drawn(@confirmation_secret_prefix, @confirmation_secret_bytes)

  @doc """
  Whether `value` is, whole, a credential of `kind`.

      iex> Prima.CredentialShape.match?(:webhook_secret, Prima.CredentialShape.mint(:webhook_secret))
      true

      iex> Prima.CredentialShape.match?(:webhook_secret, "whsec_short")
      false
  """
  @spec match?(kind(), term()) :: boolean()
  def match?(kind, value) when is_binary(value) do
    case runs(value) do
      [{0, size, ^kind}] -> size == byte_size(value)
      _ -> false
    end
  end

  def match?(_kind, _value), do: false

  @doc """
  `text` with every credential of a shape here replaced by `placeholder`,
  whole or embedded, and every other byte as it was.

      iex> Prima.CredentialShape.redact("key: whsec_" <> String.duplicate("A", 32) <> ".", "[REDACTED]")
      "key: [REDACTED]."

      iex> Prima.CredentialShape.redact("whsec_" <> String.duplicate("A", 33), "[REDACTED]")
      "whsec_" <> String.duplicate("A", 33)
  """
  @spec redact(binary(), binary()) :: binary()
  def redact(text, placeholder) when is_binary(text) and is_binary(placeholder) do
    case runs(text) do
      [] -> text
      found -> splice(text, found, placeholder)
    end
  end

  # Every credential run in `text`, as `{start, size, kind}`, in order and
  # disjoint. Each occurrence of a prefix is a candidate; one that begins
  # inside a run already taken is part of that run. A candidate reads a
  # bounded span after its prefix, never the rest of the text.
  defp runs(text) do
    matches = :binary.matches(text, prefixes())
    starts = MapSet.new(matches, &elem(&1, 0))

    {found, _end} =
      Enum.reduce(matches, {[], 0}, fn {start, length}, {acc, taken} ->
        with true <- start >= taken,
             {kind, size} <- run(text, start, length, starts) do
          {[{start, size, kind} | acc], start + size}
        else
          _ -> {acc, taken}
        end
      end)

    Enum.reverse(found)
  end

  defp prefixes, do: [@signed_token_header <> "." | Enum.map(prefixed(), &elem(&1, 1))]

  # The run a prefix at `start` begins, or nil when what follows it is not
  # the shape's. `starts` holds where every prefix in the text begins: a
  # run may end where another credential starts.
  defp run(text, start, length, starts) do
    prefix = binary_part(text, start, length)

    if prefix == @signed_token_header <> "." do
      signed_run(text, start, length, starts)
    else
      {kind, ^prefix, random} = List.keyfind(prefixed(), prefix, 1)
      # The random part, whole, and a boundary after it.
      if alphabet_run(text, start + length, random) == random and
           boundary?(text, start + length + random, starts),
         do: {kind, length + random}
    end
  end

  defp signed_run(text, start, length, starts) do
    payload = alphabet_run(text, start + length, @signed_token_payload_max + 1)
    dot = start + length + payload
    signature = signed_token_signature_length()

    if payload in 1..@signed_token_payload_max and byte_at(text, dot) == ?. and
         alphabet_run(text, dot + 1, signature) == signature and
         boundary?(text, dot + 1 + signature, starts),
       do: {:signed_token, length + payload + 1 + signature}
  end

  # A run ends at the end of the text, before a character outside the
  # alphabet, or where another credential's prefix begins.
  defp boundary?(text, at, starts) do
    case byte_at(text, at) do
      nil ->
        true

      c when c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c in [?_, ?-] ->
        MapSet.member?(starts, at)

      _other ->
        true
    end
  end

  # The number of base64url characters at `from`, counting at most `limit`.
  defp alphabet_run(text, from, limit) when from <= byte_size(text),
    do: count_alphabet(binary_part(text, from, min(limit, byte_size(text) - from)), 0)

  defp alphabet_run(_text, _from, _limit), do: 0

  defp count_alphabet(<<c, rest::binary>>, n)
       when c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c in [?_, ?-],
       do: count_alphabet(rest, n + 1)

  defp count_alphabet(_rest, n), do: n

  defp byte_at(text, at) when at < byte_size(text), do: :binary.at(text, at)
  defp byte_at(_text, _at), do: nil

  defp splice(text, found, placeholder) do
    {parts, last} =
      Enum.reduce(found, {[], 0}, fn {start, size, _kind}, {acc, from} ->
        {[placeholder, binary_part(text, from, start - from) | acc], start + size}
      end)

    IO.iodata_to_binary(Enum.reverse([binary_part(text, last, byte_size(text) - last) | parts]))
  end

  defp drawn(prefix, bytes),
    do: prefix <> Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)

  # Unpadded base64url of `bytes` bytes.
  defp encoded_length(bytes), do: div(bytes * 4 + 2, 3)
end
