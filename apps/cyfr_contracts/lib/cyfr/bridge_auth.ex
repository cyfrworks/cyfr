# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.BridgeAuth do
  @moduledoc """
  How CYFR and the MCP bridge authenticate each other: the server's half.
  The bridge's half is `apps/mcp-bridge/auth.mjs`, and
  `tests/fixtures/bridge_auth.json` holds the vectors both must reproduce.
  Both halves spell the construction `Cyfr.MacEnvelope` describes.

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
  `cyfr-bridge/v1/<kind>`, then the message's fields and the hex SHA-256 of
  the raw body, one per line. It travels in the `Cyfr-Bridge-Auth` header as
  `v1 kind=<kind>` followed by `name=value` pairs and `mac=`. Every field is
  1 to 256 bytes of printable ASCII without spaces, so neither the canonical
  string nor the header can be split ambiguously.

  A sealed environment is `base64url(iv ‖ tag ‖ ciphertext)` under
  AES-256-GCM with the seal key, its additional data naming the owner,
  generation, epoch and bridge lifetime it was sealed for.
  """

  alias Cyfr.MacEnvelope

  @owner_fields [athanor: :string, server: :string, generation: :integer, epoch: :integer]
  @seal_fields @owner_fields ++ [boot: :string]
  @header_names %{generation: "gen"}

  @invoke %MacEnvelope{
    prefix: "cyfr-bridge/v1",
    kind: "invoke",
    fields: @owner_fields ++ [boot: :string, ts: :integer, nonce: :string],
    header_names: @header_names
  }

  @control %MacEnvelope{
    prefix: "cyfr-bridge/v1",
    kind: "control",
    fields: [generation: :integer, seq: :integer, cyfr_boot: :string, boot: :string, ts: :integer],
    header_names: @header_names
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

  @doc """
  The root secret `CYFR_MCP_BRIDGE_KEY` spells: exactly 64 hexadecimal
  digits, in either case. Anything else is `:error`.
  """
  @spec decode_root(term()) :: {:ok, binary()} | :error
  defdelegate decode_root(text), to: MacEnvelope

  @doc "The key the controller signs control messages with."
  @spec control_key(binary()) :: binary()
  def control_key(root) when byte_size(root) == 32,
    do: MacEnvelope.derive(root, "cyfr-bridge/v1/control")

  @doc "The key backend environment values are sealed with."
  @spec seal_key(binary()) :: binary()
  def seal_key(root) when byte_size(root) == 32,
    do: MacEnvelope.derive(root, "cyfr-bridge/v1/seal")

  @doc "The key one owner, at one generation and epoch, signs its requests with."
  @spec owner_key(binary(), owner()) :: {:ok, binary()} | {:error, {:invalid_field, atom()}}
  def owner_key(root, owner) when byte_size(root) == 32,
    do: MacEnvelope.derive(root, "cyfr-bridge/v1/owner", @owner_fields, owner)

  @doc "The `Cyfr-Bridge-Auth` header for an invoke of `body` signed with the owner's key."
  @spec invoke_header(binary(), invoke(), binary()) ::
          {:ok, String.t()} | {:error, {:invalid_field, atom()}}
  def invoke_header(owner_key, invoke, body) when is_binary(body),
    do: MacEnvelope.header(@invoke, owner_key, invoke, body)

  @doc "The `Cyfr-Bridge-Auth` header for a control message of `body` signed with the control key."
  @spec control_header(binary(), control(), binary()) ::
          {:ok, String.t()} | {:error, {:invalid_field, atom()}}
  def control_header(control_key, control, body) when is_binary(body),
    do: MacEnvelope.header(@control, control_key, control, body)

  @doc "The canonical string a signature covers."
  @spec canonical(:invoke | :control, map(), binary()) ::
          {:ok, String.t()} | {:error, {:invalid_field, atom()}}
  def canonical(:invoke, message, body) when is_binary(body),
    do: MacEnvelope.canonical(@invoke, message, body)

  def canonical(:control, message, body) when is_binary(body),
    do: MacEnvelope.canonical(@control, message, body)

  @doc """
  An invoke's or control message's fields and MAC from its `Cyfr-Bridge-Auth`
  header, or `{:error, :malformed}` for anything but exactly one well-formed
  header of that kind.
  """
  @spec parse_header(:invoke | :control, term()) ::
          {:ok, map(), String.t()} | {:error, :malformed}
  def parse_header(:invoke, header), do: MacEnvelope.parse(@invoke, header)
  def parse_header(:control, header), do: MacEnvelope.parse(@control, header)

  @doc "Whether `mac` signs the message's fields and `body` with `key`, compared in constant time."
  @spec verify(:invoke | :control, binary(), map(), String.t(), binary()) :: boolean()
  def verify(:invoke, key, message, mac, body),
    do: MacEnvelope.verify(@invoke, key, message, mac, body)

  def verify(:control, key, message, mac, body),
    do: MacEnvelope.verify(@control, key, message, mac, body)

  @doc """
  Seal a backend environment's JSON for one owner in one bridge lifetime.
  `iv` is 12 random bytes unless given.
  """
  @spec seal(binary(), owner(), String.t(), binary(), binary()) ::
          {:ok, String.t()} | {:error, {:invalid_field, atom()}}
  def seal(seal_key, owner, boot, plaintext, iv \\ :crypto.strong_rand_bytes(12))
      when byte_size(iv) == 12 and is_binary(plaintext) do
    MacEnvelope.seal(
      seal_key,
      "cyfr-bridge/v1/seal",
      @seal_fields,
      Map.put(owner, :boot, boot),
      plaintext,
      iv
    )
  end

  @doc "Open what `seal/5` sealed for the same owner and bridge lifetime."
  @spec open(binary(), owner(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, :unsealable | {:invalid_field, atom()}}
  def open(seal_key, owner, boot, sealed) when is_binary(sealed),
    do:
      MacEnvelope.open(
        seal_key,
        "cyfr-bridge/v1/seal",
        @seal_fields,
        Map.put(owner, :boot, boot),
        sealed
      )
end
