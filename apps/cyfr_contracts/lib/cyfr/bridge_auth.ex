# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.BridgeAuth do
  @moduledoc """
  How CYFR and the MCP bridge authenticate each other: the server's half.
  The bridge's half is `apps/mcp-bridge/auth.mjs`, and
  `tests/fixtures/bridge_auth.json` holds the vectors both must reproduce.

  One root secret of 32 bytes is shared by the server and the bridge
  (`CYFR_MCP_BRIDGE_KEY`). Every other key is derived from it with
  HMAC-SHA256 over a label, so nothing but the root is configured and
  nothing is stored:

    * the **control key** signs the controller's messages to the bridge;
    * the **seal key** encrypts backend environment values in transit;
    * an **owner key** — one per athanor, server row, control-plane
      generation and owner epoch — signs that owner's MCP requests, and is
      the only key the owner's process holds.

  A signature is the unpadded base64url HMAC-SHA256 of a canonical string:
  the message kind, then its fields and the hex SHA-256 of the raw body, one
  per line. It travels in the `Cyfr-Bridge-Auth` header as
  `v1 kind=<kind>` followed by `name=value` pairs and `mac=`. Every field is
  1 to 256 bytes of printable ASCII without spaces, so neither the canonical
  string nor the header can be split ambiguously.

  A sealed environment is `base64url(iv ‖ tag ‖ ciphertext)` under
  AES-256-GCM with the seal key, its additional data naming the owner,
  generation, epoch and bridge lifetime it was sealed for.
  """

  @version "v1"
  @field ~r/\A[\x21-\x7E]{1,256}\z/

  @invoke_fields [:athanor, :server, :generation, :epoch, :boot, :ts, :nonce]
  @control_fields [:generation, :seq, :cyfr_boot, :boot, :ts]
  @header_names %{
    athanor: "athanor",
    server: "server",
    generation: "gen",
    epoch: "epoch",
    boot: "boot",
    ts: "ts",
    nonce: "nonce",
    seq: "seq",
    cyfr_boot: "cyfr_boot"
  }

  @typedoc "The owner a key or a sealed environment is bound to."
  @type owner :: %{
          athanor: String.t(),
          server: String.t(),
          generation: pos_integer(),
          epoch: pos_integer()
        }

  @typedoc "An invoke's fields: the owner's, the bridge lifetime, the timestamp in ms and a nonce."
  @type invoke :: %{
          athanor: String.t(),
          server: String.t(),
          generation: pos_integer(),
          epoch: pos_integer(),
          boot: String.t(),
          ts: non_neg_integer(),
          nonce: String.t()
        }

  @typedoc "A control message's fields: generation, sequence, both lifetimes and the timestamp."
  @type control :: %{
          generation: pos_integer(),
          seq: pos_integer(),
          cyfr_boot: String.t(),
          boot: String.t(),
          ts: non_neg_integer()
        }

  @doc "The key the controller signs control messages with."
  @spec control_key(binary()) :: binary()
  def control_key(root) when byte_size(root) == 32, do: derive(root, "cyfr-bridge/v1/control")

  @doc "The key backend environment values are sealed with."
  @spec seal_key(binary()) :: binary()
  def seal_key(root) when byte_size(root) == 32, do: derive(root, "cyfr-bridge/v1/seal")

  @doc "The key one owner, at one generation and epoch, signs its requests with."
  @spec owner_key(binary(), owner()) :: {:ok, binary()} | {:error, {:invalid_field, atom()}}
  def owner_key(root, owner) when byte_size(root) == 32 do
    with {:ok, [athanor, server, generation, epoch]} <-
           fields(owner, [:athanor, :server, :generation, :epoch]) do
      label = Enum.join(["cyfr-bridge/v1/owner", athanor, server, generation, epoch], "\n")
      {:ok, derive(root, label)}
    end
  end

  @doc "The `Cyfr-Bridge-Auth` header for an invoke of `body` signed with the owner's key."
  @spec invoke_header(binary(), invoke(), binary()) ::
          {:ok, String.t()} | {:error, {:invalid_field, atom()}}
  def invoke_header(owner_key, invoke, body) when is_binary(body),
    do: header("invoke", owner_key, invoke, @invoke_fields, body)

  @doc "The `Cyfr-Bridge-Auth` header for a control message of `body` signed with the control key."
  @spec control_header(binary(), control(), binary()) ::
          {:ok, String.t()} | {:error, {:invalid_field, atom()}}
  def control_header(control_key, control, body) when is_binary(body),
    do: header("control", control_key, control, @control_fields, body)

  @doc "The canonical string a signature covers."
  @spec canonical(:invoke | :control, map(), binary()) ::
          {:ok, String.t()} | {:error, {:invalid_field, atom()}}
  def canonical(kind, message, body) when kind in [:invoke, :control] and is_binary(body) do
    names = if kind == :invoke, do: @invoke_fields, else: @control_fields

    with {:ok, values} <- fields(message, names) do
      body_hash = Cyfr.Digest.sha256_hex(body)
      {:ok, Enum.join(["cyfr-bridge/#{@version}/#{kind}" | values] ++ [body_hash], "\n")}
    end
  end

  @doc """
  Seal a backend environment's JSON for one owner in one bridge lifetime.
  `iv` is 12 random bytes unless given.
  """
  @spec seal(binary(), owner(), String.t(), binary(), binary()) ::
          {:ok, String.t()} | {:error, {:invalid_field, atom()}}
  def seal(seal_key, owner, boot, plaintext, iv \\ :crypto.strong_rand_bytes(12))
      when byte_size(iv) == 12 and is_binary(plaintext) do
    with {:ok, aad} <- seal_aad(owner, boot) do
      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, seal_key, iv, plaintext, aad, true)

      {:ok, Base.url_encode64(iv <> tag <> ciphertext, padding: false)}
    end
  end

  @doc "Open what `seal/5` sealed for the same owner and bridge lifetime."
  @spec open(binary(), owner(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, :unsealable | {:invalid_field, atom()}}
  def open(seal_key, owner, boot, sealed) when is_binary(sealed) do
    with {:ok, aad} <- seal_aad(owner, boot),
         {:ok, <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>} <-
           Base.url_decode64(sealed, padding: false),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, seal_key, iv, ciphertext, aad, tag, false) do
      {:ok, plaintext}
    else
      {:error, {:invalid_field, _}} = invalid -> invalid
      _ -> {:error, :unsealable}
    end
  end

  defp header(kind, key, message, names, body) do
    with {:ok, canonical} <- canonical(String.to_existing_atom(kind), message, body),
         {:ok, values} <- fields(message, names) do
      pairs =
        Enum.zip_with(names, values, fn name, value -> "#{@header_names[name]}=#{value}" end)

      mac = :crypto.mac(:hmac, :sha256, key, canonical) |> Base.url_encode64(padding: false)
      {:ok, Enum.join(["#{@version} kind=#{kind}" | pairs] ++ ["mac=#{mac}"], " ")}
    end
  end

  defp seal_aad(owner, boot) do
    with {:ok, values} <-
           fields(Map.put(owner, :boot, boot), [:athanor, :server, :generation, :epoch, :boot]) do
      {:ok, Enum.join(["cyfr-bridge/v1/seal" | values], "\n")}
    end
  end

  defp fields(message, names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case field(Map.get(message, name)) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, {:error, {:invalid_field, name}}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp field(value) when is_integer(value) and value >= 0, do: field(Integer.to_string(value))

  defp field(value) when is_binary(value),
    do: if(Regex.match?(@field, value), do: {:ok, value}, else: :error)

  defp field(_value), do: :error

  defp derive(root, label), do: :crypto.mac(:hmac, :sha256, root, label)
end
