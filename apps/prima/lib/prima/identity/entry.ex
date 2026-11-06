# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Identity.Entry do
  @moduledoc """
  One entry of an account's log, `cyfr-identity/v2`. Every entry carries
  `protocol`, `kind`, `seq` (0 on the genesis, one more than the head's on
  every other), `at` (Unix milliseconds), `signer` and `sig`; every entry
  but the genesis carries `prev`, the head's hash. Each kind adds exactly
  its fields:

    * `genesis` — `directory`, the URL of the directory that orders the
      log, and `recovery`, 1 to 8 distinct Ed25519 recovery public keys.
    * `add_key` — `key`, a `Prima.Identity.Key`.
    * `remove_key` — `kid`, the key it removes.
    * `recover` — `keys`, 0 to 64 keys, and `recovery`, 1 to 8 recovery
      keys: the account's whole key set and recovery set from here on.
    * `add_recovery` — `recovery`, 1 to 8 recovery keys, the whole new set.

  `signer` names the key that signed: a listed key's `kid`, or
  `recovery:<kid>` for a recovery key, whose `kid` is `sha256:<hex>` over
  its public key. `sig` is an Ed25519 signature (unpadded base64url) for an
  Ed25519 signer, or a passkey's `Prima.Identity.WebAuthn` assertion for an
  ES256 one; which of them the signer may sign, and with which key, is the
  chain's check (`Prima.Identity.extend/2`).

  An entry's JCS form is at most `Prima.Identity.max_entry_bytes/0`; a
  larger one is `:too_large` before its fields are read.
  """

  alias Prima.Identity
  alias Prima.Identity.{Encoding, Key, WebAuthn}

  @type kind :: :genesis | :add_key | :remove_key | :recover | :add_recovery
  @type sig :: binary() | WebAuthn.t()

  @type t :: %__MODULE__{
          kind: kind(),
          prev: String.t() | nil,
          seq: non_neg_integer(),
          at: non_neg_integer(),
          signer: String.t(),
          sig: sig() | nil,
          directory: String.t() | nil,
          recovery: [binary()] | nil,
          key: Key.t() | nil,
          kid: String.t() | nil,
          keys: [Key.t()] | nil
        }

  @enforce_keys [:kind, :seq, :at, :signer]
  defstruct [:kind, :prev, :seq, :at, :signer, :sig, :directory, :recovery, :key, :kid, :keys]

  @kinds %{
    "genesis" => :genesis,
    "add_key" => :add_key,
    "remove_key" => :remove_key,
    "recover" => :recover,
    "add_recovery" => :add_recovery
  }

  @common ~w(protocol kind seq at signer)

  @fields %{
    genesis: ~w(directory recovery),
    add_key: ~w(prev key),
    remove_key: ~w(prev kid),
    recover: ~w(prev keys recovery),
    add_recovery: ~w(prev recovery)
  }

  @signer ~r/\A(?:recovery:)?sha256:[0-9a-f]{64}\z/

  @doc """
  An unsigned entry from its fields (atom keys: `kind` and the kind's
  fields; public keys as raw bytes, `key` and `keys` as
  `Prima.Identity.Key` structs). Sign it with `Prima.Identity.sign/2`, or
  attach a passkey's assertion with `Prima.Identity.attach/2`.
  """
  @spec new(map() | keyword()) ::
          {:ok, t()} | {:error, Encoding.reason() | :too_large | {:unknown_kind, term()}}
  def new(attrs) do
    attrs = Map.new(attrs)

    %{
      "protocol" => Identity.protocol(),
      "kind" => attrs[:kind] && Atom.to_string(attrs[:kind]),
      "prev" => attrs[:prev],
      "seq" => attrs[:seq],
      "at" => attrs[:at],
      "signer" => attrs[:signer],
      "directory" => attrs[:directory],
      "recovery" => attrs[:recovery] && Encoding.b64_keys(attrs[:recovery]),
      "key" => attrs[:key] && Key.encode(attrs[:key]),
      "kid" => attrs[:kid],
      "keys" => attrs[:keys] && Enum.map(attrs[:keys], &Key.encode/1)
    }
    |> Encoding.compact()
    |> read(false)
  end

  @doc "Read a signed entry from its JSON map."
  @spec decode(term()) ::
          {:ok, t()}
          | {:error, Encoding.reason() | :wrong_protocol | :too_large | {:unknown_kind, term()}}
  def decode(map), do: read(map, true)

  @doc "The JSON map of an entry; `sig` is absent while unsigned."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = entry) do
    Encoding.compact(%{
      "protocol" => Identity.protocol(),
      "kind" => Atom.to_string(entry.kind),
      "prev" => entry.prev,
      "seq" => entry.seq,
      "at" => entry.at,
      "signer" => entry.signer,
      "directory" => entry.directory,
      "recovery" => entry.recovery && Encoding.b64_keys(entry.recovery),
      "key" => entry.key && Key.encode(entry.key),
      "kid" => entry.kid,
      "keys" => entry.keys && Enum.map(entry.keys, &Key.encode/1),
      "sig" => encode_sig(entry.sig)
    })
  end

  defp encode_sig(nil), do: nil
  defp encode_sig(sig) when is_binary(sig), do: Encoding.b64(sig)
  defp encode_sig(sig), do: WebAuthn.encode(sig)

  defp read(map, signed?) when is_map(map) and not is_struct(map) do
    with {:ok, bytes} <- Encoding.jcs(map),
         :ok <- size(bytes),
         :ok <- Encoding.protocol(map, Identity.protocol()),
         {:ok, kind} <- kind(map),
         :ok <- Encoding.fields(map, fields(kind, signed?), []),
         {:ok, seq} <- seq(map, kind),
         {:ok, at} <- Encoding.check(map, "at", &Encoding.ms?/1),
         {:ok, signer} <- Encoding.check(map, "signer", &signer?/1),
         {:ok, prev} <- prev(map, kind),
         {:ok, entry} <- read_kind(kind, map),
         {:ok, sig} <- signature(map, signed?) do
      {:ok, %{entry | kind: kind, prev: prev, seq: seq, at: at, signer: signer, sig: sig}}
    end
  end

  defp read(_value, _signed?), do: {:error, {:invalid_field, "entry"}}

  defp read_kind(:genesis, map) do
    with {:ok, directory} <- Encoding.check(map, "directory", &Encoding.directory_url?/1),
         {:ok, recovery} <- recovery(map) do
      {:ok, blank(directory: directory, recovery: recovery)}
    end
  end

  defp read_kind(:add_key, map) do
    case Key.decode(map["key"]) do
      {:ok, key} -> {:ok, blank(key: key)}
      :error -> {:error, {:invalid_field, "key"}}
    end
  end

  defp read_kind(:remove_key, map) do
    with {:ok, kid} <- Encoding.check(map, "kid", &Encoding.digest?/1),
         do: {:ok, blank(kid: kid)}
  end

  defp read_kind(:recover, map) do
    with {:ok, keys} <- keys(map),
         {:ok, recovery} <- recovery(map),
         do: {:ok, blank(keys: keys, recovery: recovery)}
  end

  defp read_kind(:add_recovery, map) do
    with {:ok, recovery} <- recovery(map), do: {:ok, blank(recovery: recovery)}
  end

  defp blank(fields),
    do: struct!(__MODULE__, [kind: nil, seq: nil, at: nil, signer: nil] ++ fields)

  defp size(bytes) do
    if byte_size(bytes) > Identity.max_entry_bytes(), do: {:error, :too_large}, else: :ok
  end

  defp kind(map) do
    case Map.fetch(map, "kind") do
      {:ok, name} when is_map_key(@kinds, name) -> {:ok, Map.fetch!(@kinds, name)}
      {:ok, name} -> {:error, {:unknown_kind, name}}
      :error -> {:error, {:missing_field, "kind"}}
    end
  end

  defp fields(kind, true), do: @common ++ Map.fetch!(@fields, kind) ++ ["sig"]
  defp fields(kind, false), do: @common ++ Map.fetch!(@fields, kind)

  # The genesis is the log's first entry; every other entry's position is
  # checked against the head by the chain (`Prima.Identity.extend/2`).
  defp seq(map, :genesis), do: Encoding.check(map, "seq", &(&1 === 0))
  defp seq(map, _kind), do: Encoding.check(map, "seq", &Encoding.ms?/1)

  defp prev(_map, :genesis), do: {:ok, nil}
  defp prev(map, _kind), do: Encoding.check(map, "prev", &Encoding.digest?/1)

  defp signer?(value), do: is_binary(value) and Regex.match?(@signer, value)

  defp recovery(map) do
    with {:ok, keys} <- Encoding.keys(map, "recovery") do
      if length(keys) <= Identity.max_recovery(),
        do: {:ok, keys},
        else: {:error, {:invalid_field, "recovery"}}
    end
  end

  defp keys(map) do
    with list when is_list(list) <- map["keys"],
         true <- length(list) <= Identity.max_keys(),
         decoded = Enum.map(list, &Key.decode/1),
         false <- Enum.member?(decoded, :error) do
      {:ok, Enum.map(decoded, fn {:ok, key} -> key end)}
    else
      _ -> {:error, {:invalid_field, "keys"}}
    end
  end

  defp signature(_map, false), do: {:ok, nil}

  defp signature(map, true) do
    case map["sig"] do
      sig when is_binary(sig) ->
        case Encoding.signature(sig) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, {:invalid_field, "sig"}}
        end

      sig ->
        case WebAuthn.decode(sig) do
          {:ok, assertion} -> {:ok, assertion}
          :error -> {:error, {:invalid_field, "sig"}}
        end
    end
  end
end
