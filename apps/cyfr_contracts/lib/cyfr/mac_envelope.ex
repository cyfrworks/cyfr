# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.MacEnvelope do
  @moduledoc """
  The construction two parties sharing a 32-byte root secret use to
  authenticate messages and seal values to each other. `Cyfr.BridgeAuth`
  (CYFR and the MCP bridge) and `Cyfr.WorkerAuth` (CYFR and its execution
  workers) are built on it.

    * **Keys** are HMAC-SHA256 of the root over a label, or over a label
      followed by field values one per line (`derive/2`, `derive/4`), so
      nothing but the root is configured and nothing is stored.
    * **A signature** is the unpadded base64url HMAC-SHA256 of a canonical
      string (`canonical/3`): `<prefix>/<kind>`, then the message's field
      values in the envelope's order, then the hex SHA-256 of the raw body,
      one per line.
    * **A header** (`header/4`) carries the signature as
      `v1 kind=<kind> name=value … mac=<mac>`. `parse/2` reads it back and
      `verify/5` checks its MAC in constant time.
    * **A sealed value** (`seal/6`) is `base64url(iv ‖ tag ‖ ciphertext)`,
      unpadded, under AES-256-GCM, its additional data a label followed by
      field values one per line; `open/5` opens it under the same label and
      values only.

  Every field value is 1 to 256 bytes of printable ASCII without spaces. An
  `:integer` field takes an integer from 0 to 2^53 − 1 and is written in
  decimal without leading zeros; a `:string` field takes a string, whatever
  it spells. A value outside that is `{:error, {:invalid_field, name}}`, so
  no canonical string, label or header can be split ambiguously, and every
  party reads an integer field as the same number.

  An envelope (`t:t/0`) describes one message type: its `prefix`, its `kind`
  and its ordered `fields`. A field's header name is its atom's name unless
  `header_names` gives another.
  """

  @enforce_keys [:prefix, :kind, :fields]
  defstruct [:prefix, :kind, :fields, header_names: %{}]

  @type field_type :: :string | :integer
  @type fields :: [{atom(), field_type()}]

  @type t :: %__MODULE__{
          prefix: String.t(),
          kind: String.t(),
          fields: fields(),
          header_names: %{optional(atom()) => String.t()}
        }

  @typedoc "A message's fields by name: strings and non-negative integers."
  @type message :: %{optional(atom()) => String.t() | non_neg_integer()}

  @type invalid_field :: {:invalid_field, atom()}

  @version "v1"
  @text ~r/\A[\x21-\x7E]{1,256}\z/
  @decimal ~r/\A(0|[1-9][0-9]*)\z/
  # 2^53 − 1: every integer up to it is exact in an IEEE 754 double.
  @max_integer 9_007_199_254_740_991

  @doc "The key HMAC-SHA256 of `root` over `label` derives."
  @spec derive(binary(), String.t()) :: binary()
  def derive(root, label) when byte_size(root) == 32 and is_binary(label),
    do: :crypto.mac(:hmac, :sha256, root, label)

  @doc "The key derived from `root` over `label` and the message's `fields`, one per line."
  @spec derive(binary(), String.t(), fields(), message()) ::
          {:ok, binary()} | {:error, invalid_field()}
  def derive(root, label, fields, message)
      when byte_size(root) == 32 and is_binary(label) and is_map(message) do
    with {:ok, lines} <- lines(label, fields, message), do: {:ok, derive(root, lines)}
  end

  @doc "The canonical string a signature of `message` and `body` covers."
  @spec canonical(t(), message(), binary()) :: {:ok, String.t()} | {:error, invalid_field()}
  def canonical(%__MODULE__{} = envelope, message, body)
      when is_map(message) and is_binary(body) do
    with {:ok, values} <- values(envelope.fields, message) do
      {:ok, canonical_string(envelope, values, body)}
    end
  end

  @doc "The `v1` header carrying the signature of `message` and `body` with `key`."
  @spec header(t(), binary(), message(), binary()) ::
          {:ok, String.t()} | {:error, invalid_field()}
  def header(%__MODULE__{} = envelope, key, message, body)
      when is_binary(key) and is_map(message) and is_binary(body) do
    with {:ok, values} <- values(envelope.fields, message) do
      pairs =
        Enum.zip_with(envelope.fields, values, fn {name, _type}, value ->
          "#{header_name(envelope, name)}=#{value}"
        end)

      mac = mac(key, canonical_string(envelope, values, body))
      {:ok, Enum.join(["#{@version} kind=#{envelope.kind}" | pairs] ++ ["mac=#{mac}"], " ")}
    end
  end

  @doc """
  A header's fields and MAC. A header is `v1` followed by `name=value`
  tokens, each separated by one space: `kind` naming the envelope's kind,
  every field once under its header name, and `mac`, in any order and
  nothing else. A name is everything before a token's first `=`; a field
  value and the MAC are valid field text, and an integer field's value is
  its decimal spelling. Anything else is `{:error, :malformed}`. Integer
  fields come back as integers.
  """
  @spec parse(t(), term()) :: {:ok, message(), String.t()} | {:error, :malformed}
  def parse(%__MODULE__{} = envelope, header) when is_binary(header) do
    with [@version | tokens] <- String.split(header, " "),
         {:ok, pairs} <- pairs(tokens),
         true <- Enum.sort(Map.keys(pairs)) == expected_names(envelope),
         true <- pairs["kind"] == envelope.kind and Regex.match?(@text, pairs["mac"]),
         {:ok, message} <- read_fields(envelope, pairs) do
      {:ok, message, pairs["mac"]}
    else
      _ -> {:error, :malformed}
    end
  end

  def parse(%__MODULE__{}, _header), do: {:error, :malformed}

  @doc """
  Whether `mac` is the signature of `message` and `body` with `key`,
  compared in constant time. A message with an invalid field is not.
  """
  @spec verify(t(), binary(), message(), String.t(), binary()) :: boolean()
  def verify(%__MODULE__{} = envelope, key, message, mac, body)
      when is_binary(key) and is_map(message) and is_binary(mac) and is_binary(body) do
    case values(envelope.fields, message) do
      {:ok, values} ->
        expected = mac(key, canonical_string(envelope, values, body))
        byte_size(expected) == byte_size(mac) and :crypto.hash_equals(expected, mac)

      {:error, _} ->
        false
    end
  end

  @doc """
  Seal `plaintext` with a 32-byte `key` to `label` and the message's
  `fields`. `iv` is 12 random bytes unless given.
  """
  @spec seal(binary(), String.t(), fields(), message(), binary(), binary()) ::
          {:ok, String.t()} | {:error, invalid_field()}
  def seal(key, label, fields, message, plaintext, iv \\ :crypto.strong_rand_bytes(12))
      when byte_size(key) == 32 and is_binary(label) and is_map(message) and is_binary(plaintext) and
             byte_size(iv) == 12 do
    with {:ok, aad} <- lines(label, fields, message) do
      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, true)

      {:ok, Base.url_encode64(iv <> tag <> ciphertext, padding: false)}
    end
  end

  @doc """
  Open what `seal/6` sealed with the same key, label and field values.
  Anything else is `{:error, :unsealable}`.
  """
  @spec open(binary(), String.t(), fields(), message(), term()) ::
          {:ok, binary()} | {:error, :unsealable | invalid_field()}
  def open(key, label, fields, message, sealed)
      when byte_size(key) == 32 and is_binary(label) and is_map(message) do
    with {:ok, aad} <- lines(label, fields, message), do: decrypt(key, aad, sealed)
  end

  defp decrypt(key, aad, sealed) when is_binary(sealed) do
    with {:ok, <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>} <-
           Base.url_decode64(sealed, padding: false),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, aad, tag, false) do
      {:ok, plaintext}
    else
      _ -> {:error, :unsealable}
    end
  end

  defp decrypt(_key, _aad, _sealed), do: {:error, :unsealable}

  defp canonical_string(envelope, values, body) do
    Enum.join(
      ["#{envelope.prefix}/#{envelope.kind}" | values] ++ [Cyfr.Digest.sha256_hex(body)],
      "\n"
    )
  end

  defp mac(key, text),
    do: :crypto.mac(:hmac, :sha256, key, text) |> Base.url_encode64(padding: false)

  defp lines(label, fields, message) do
    with {:ok, values} <- values(fields, message), do: {:ok, Enum.join([label | values], "\n")}
  end

  defp values(fields, message) do
    fields
    |> Enum.reduce_while([], fn {name, type}, acc ->
      case write_value(type, Map.get(message, name)) do
        {:ok, value} -> {:cont, [value | acc]}
        :error -> {:halt, {:error, {:invalid_field, name}}}
      end
    end)
    |> case do
      {:error, _} = invalid -> invalid
      values -> {:ok, Enum.reverse(values)}
    end
  end

  defp write_value(:integer, value) when is_integer(value) and value in 0..@max_integer,
    do: text(Integer.to_string(value))

  defp write_value(:string, value) when is_binary(value), do: text(value)
  defp write_value(_type, _value), do: :error

  defp text(value), do: if(Regex.match?(@text, value), do: {:ok, value}, else: :error)

  defp header_name(envelope, name),
    do: Map.get(envelope.header_names, name, Atom.to_string(name))

  defp expected_names(envelope) do
    Enum.sort(["kind", "mac" | Enum.map(envelope.fields, &header_name(envelope, elem(&1, 0)))])
  end

  defp pairs(tokens) do
    Enum.reduce_while(tokens, {:ok, %{}}, fn token, {:ok, pairs} ->
      case String.split(token, "=", parts: 2) do
        [name, value] when name != "" and not is_map_key(pairs, name) ->
          {:cont, {:ok, Map.put(pairs, name, value)}}

        _ ->
          {:halt, :error}
      end
    end)
  end

  defp read_fields(envelope, pairs) do
    Enum.reduce_while(envelope.fields, {:ok, %{}}, fn {name, type}, {:ok, message} ->
      case read_value(type, Map.fetch!(pairs, header_name(envelope, name))) do
        {:ok, value} -> {:cont, {:ok, Map.put(message, name, value)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp read_value(:string, value), do: text(value)

  defp read_value(:integer, value) do
    with {:ok, text} <- text(value),
         true <- Regex.match?(@decimal, text),
         integer when integer <= @max_integer <- String.to_integer(text) do
      {:ok, integer}
    else
      _ -> :error
    end
  end
end
