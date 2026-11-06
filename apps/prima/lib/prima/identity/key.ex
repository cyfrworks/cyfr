# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Identity.Key do
  @moduledoc """
  A public key an account's log lists: `kid`, `alg`, `kind` and `pub`, and
  `credential_id` for a passkey. `kid` is `Prima.Digest.sha256/1` over the
  `pub` bytes. Exactly two combinations exist:

    * `alg` `ed25519`, `kind` `device`: `pub` is the 32-byte Ed25519 key,
      and there is no `credential_id`.
    * `alg` `es256`, `kind` `passkey`: `pub` is the 65-byte uncompressed
      SEC1 P-256 point (`0x04 ‖ X ‖ Y`), and `credential_id` is the
      credential's raw id, 1 to 1023 bytes.

  Any other combination, or a `kid` that is not its `pub`'s, is not a key.
  A key carries no label, name or address.
  """

  alias Prima.Identity.Encoding

  @point_bytes 65
  @max_credential_id_bytes 1023

  @type alg :: :ed25519 | :es256
  @type kind :: :device | :passkey
  @type t :: %__MODULE__{
          kid: String.t(),
          alg: alg(),
          kind: kind(),
          pub: binary(),
          credential_id: binary() | nil
        }

  @enforce_keys [:kid, :alg, :kind, :pub]
  defstruct [:kid, :alg, :kind, :pub, credential_id: nil]

  @doc "A public key's `kid`: `sha256:<hex>` over its bytes."
  @spec kid(binary()) :: String.t()
  def kid(pub) when is_binary(pub), do: Prima.Digest.sha256(pub)

  @doc """
  A key from its public bytes (atom keys: `alg`, `kind`, `pub` and, for a
  passkey, `credential_id`), its `kid` computed. `:error` for any
  combination `decode/1` refuses.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | :error
  def new(attrs) do
    attrs = Map.new(attrs)

    if is_binary(attrs[:pub]) do
      %{
        "kid" => kid(attrs[:pub]),
        "alg" => attrs[:alg] && Atom.to_string(attrs[:alg]),
        "kind" => attrs[:kind] && Atom.to_string(attrs[:kind]),
        "pub" => Encoding.b64(attrs[:pub]),
        "credential_id" => attrs[:credential_id] && Encoding.b64(attrs[:credential_id])
      }
      |> Encoding.compact()
      |> decode()
    else
      :error
    end
  end

  @doc "Read a key from its JSON map, or `:error`."
  @spec decode(term()) :: {:ok, t()} | :error
  def decode(%{"alg" => "ed25519", "kind" => "device"} = map) do
    with :ok <- Encoding.fields(map, ~w(kid alg kind pub), []),
         {:ok, pub} <- Encoding.unb64(map["pub"], Encoding.key_bytes()),
         true <- map["kid"] == kid(pub) do
      {:ok, %__MODULE__{kid: map["kid"], alg: :ed25519, kind: :device, pub: pub}}
    else
      _ -> :error
    end
  end

  def decode(%{"alg" => "es256", "kind" => "passkey"} = map) do
    with :ok <- Encoding.fields(map, ~w(kid alg kind pub credential_id), []),
         {:ok, <<4, _::binary>> = pub} <- Encoding.unb64(map["pub"], @point_bytes),
         {:ok, credential_id} <-
           Encoding.unb64(map["credential_id"], 1, @max_credential_id_bytes),
         true <- map["kid"] == kid(pub) do
      {:ok,
       %__MODULE__{
         kid: map["kid"],
         alg: :es256,
         kind: :passkey,
         pub: pub,
         credential_id: credential_id
       }}
    else
      _ -> :error
    end
  end

  def decode(_value), do: :error

  @doc "The JSON map of a key."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = key) do
    Encoding.compact(%{
      "kid" => key.kid,
      "alg" => Atom.to_string(key.alg),
      "kind" => Atom.to_string(key.kind),
      "pub" => Encoding.b64(key.pub),
      "credential_id" => key.credential_id && Encoding.b64(key.credential_id)
    })
  end
end
