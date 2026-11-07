# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Identity do
  @moduledoc """
  An account: the log that lists its keys, the identifier it hashes to, and
  the one check that walks it, `cyfr-identity/v2`.
  `tests/fixtures/identity.json` holds the vectors every side reproduces;
  the shared encodings are `Prima.Identity.Encoding`'s.

  ## The log

  An append-only sequence of `Prima.Identity.Entry`, each naming the hash
  of the entry before it (`prev`) and its position (`seq`), and signed by a
  key the log listed at the entry before it. Five kinds exist and no other
  (`kinds/0`):

  | kind | signer | effect |
  |---|---|---|
  | `genesis` | a recovery key in its own `recovery` | the account exists, with no keys; its hash is the identifier |
  | `add_key` | any listed key or recovery key | the key signs from now; a `kid` already listed is `:duplicate_key` |
  | `remove_key` | any listed key but the one removed, or a recovery key | the key stops |
  | `recover` | a recovery key | replaces every key and the recovery set |
  | `add_recovery` | a recovery key | the recovery set becomes a strict superset of itself |

  The genesis is always signed by a recovery key, so the identifier never
  depends on a passkey. A recovery key is `Prima.RecoveryCode`'s holder:
  a 32-byte seed is its Ed25519 private key (`derive_recovery_key/1`).

  ## Signatures

  An Ed25519 signer (a device key or a recovery key) signs the JCS bytes
  of the entry without `sig` (`sign/2`). A passkey's `sig` is the WebAuthn
  assertion whose challenge is those bytes' SHA-256 (`challenge/1`,
  `attach/2`), checked at the directory the genesis names: its origin, and
  its host as the relying party (`Prima.Identity.WebAuthn.verify/5`).

  `prev` records the directory's ordering, which is trusted for ordering
  alone: the identifier and every signature are checked from the genesis,
  so a fresh reader verifies the whole log from the genesis alone.

  ## The identifier and the passkey's user id

  The identifier's 32 digest bytes are the passkey's WebAuthn `user.id`
  (`user_id/1`), so an assertion's user handle names the account without a
  lookup (`identifier_for_user_id/1`).
  """

  alias Prima.Identity.{Encoding, Entry, Key, State, WebAuthn}

  @protocol "cyfr-identity/v2"
  @prefix "per"
  @max_entry_bytes 16_384
  @max_recovery 8
  @max_keys 64
  @seed_bytes 32
  @digest_bytes 32

  @type reason ::
          Encoding.reason()
          | :wrong_protocol
          | :too_large
          | {:unknown_kind, term()}
          | :not_genesis
          | :unexpected_genesis
          | :broken_link
          | :wrong_signer
          | :duplicate_key

  @doc "The protocol string every entry carries."
  @spec protocol() :: String.t()
  def protocol, do: @protocol

  @doc "The identifier's prefix."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "The largest entry, in bytes of its JCS form."
  @spec max_entry_bytes() :: pos_integer()
  def max_entry_bytes, do: @max_entry_bytes

  @doc "The most recovery keys a set holds."
  @spec max_recovery() :: pos_integer()
  def max_recovery, do: @max_recovery

  @doc "The most keys a `recover` entry lists."
  @spec max_keys() :: pos_integer()
  def max_keys, do: @max_keys

  @doc "The five entry kinds, exhaustively."
  @spec kinds() :: [Entry.kind()]
  def kinds, do: [:genesis, :add_key, :remove_key, :recover, :add_recovery]

  @doc "The JCS bytes of an entry, `sig` included."
  @spec canonical(Entry.t()) :: binary()
  def canonical(%Entry{} = entry), do: entry |> Entry.encode() |> Encoding.jcs!()

  @doc "The bytes an entry's signer signs: its JCS form without `sig`."
  @spec signing_bytes(Entry.t()) :: binary()
  def signing_bytes(%Entry{} = entry), do: canonical(%{entry | sig: nil})

  @doc "A passkey's WebAuthn challenge for an entry: SHA-256 of its `signing_bytes/1`."
  @spec challenge(Entry.t()) :: binary()
  def challenge(%Entry{} = entry), do: :crypto.hash(:sha256, signing_bytes(entry))

  @doc "Sign an entry with an Ed25519 private key, a device's or a recovery key's."
  @spec sign(Entry.t(), binary()) :: Entry.t()
  def sign(%Entry{} = entry, private_key) do
    %{entry | sig: :crypto.sign(:eddsa, :none, signing_bytes(entry), [private_key, :ed25519])}
  end

  @doc "Attach a passkey's assertion over `challenge/1` as an entry's `sig`."
  @spec attach(Entry.t(), WebAuthn.t()) :: Entry.t()
  def attach(
        %Entry{} = entry,
        %{authenticator_data: _, client_data: _, signature: _} = assertion
      ),
      do: %{entry | sig: assertion}

  @doc "A key's `kid`: `sha256:<hex>` over its public key's bytes."
  @spec kid(binary()) :: String.t()
  def kid(pub), do: Key.kid(pub)

  @doc "The `signer` a recovery public key signs as: `recovery:` and its `kid`."
  @spec recovery_signer(binary()) :: String.t()
  def recovery_signer(pub), do: "recovery:" <> kid(pub)

  @doc """
  The identifier a genesis hashes to: `per_` and the lowercase hex of
  SHA-256 over its JCS bytes. A map is read as an entry first; anything
  that is not a genesis raises.
  """
  @spec identifier(Entry.t() | map()) :: String.t()
  def identifier(%Entry{kind: :genesis} = genesis),
    do: @prefix <> "_" <> Prima.Digest.sha256_hex(canonical(genesis))

  def identifier(map) when is_map(map) and not is_struct(map) do
    case Entry.decode(map) do
      {:ok, %Entry{kind: :genesis} = genesis} -> identifier(genesis)
      _other -> raise ArgumentError, "not a genesis entry"
    end
  end

  @doc "An entry's hash, `sha256:<hex>` over its JCS bytes: what the next entry's `prev` names."
  @spec hash(Entry.t()) :: String.t()
  def hash(%Entry{} = entry), do: Prima.Digest.sha256(canonical(entry))

  @doc "The 32 digest bytes an identifier spells: a passkey's WebAuthn `user.id`."
  @spec user_id(term()) :: {:ok, binary()} | :error
  def user_id(@prefix <> "_" <> hex = identifier) do
    if Encoding.identifier?(identifier),
      do: Base.decode16(hex, case: :lower),
      else: :error
  end

  def user_id(_identifier), do: :error

  @doc "The identifier a passkey's user handle names: `per_` and the lowercase hex of its 32 bytes."
  @spec identifier_for_user_id(term()) :: {:ok, String.t()} | :error
  def identifier_for_user_id(bytes) when is_binary(bytes) and byte_size(bytes) == @digest_bytes,
    do: {:ok, @prefix <> "_" <> Base.encode16(bytes, case: :lower)}

  def identifier_for_user_id(_bytes), do: :error

  @doc "The recovery key pair, `{public, private}`, a 32-byte seed derives (RFC 8032)."
  @spec derive_recovery_key(binary()) :: {:ok, {binary(), binary()}} | {:error, :invalid_seed}
  def derive_recovery_key(seed) when is_binary(seed) and byte_size(seed) == @seed_bytes,
    do: {:ok, :crypto.generate_key(:eddsa, :ed25519, seed)}

  def derive_recovery_key(_seed), do: {:error, :invalid_seed}

  @doc """
  Walk a log from its genesis and answer its state, or the index of the
  first entry refused and why: a first entry that is not a genesis, a later
  genesis, an entry whose `prev` is not the head's hash or whose `seq` is
  not one past the head's (`:broken_link`), a signer the kind does not take
  or a signature that does not verify (`:wrong_signer`), a key listed twice
  (`:duplicate_key`), a `remove_key` naming no listed key, an
  `add_recovery` that is not a strict superset (each `:invalid_field`), an
  unknown kind or a malformed entry.
  """
  @spec verify_chain([Entry.t() | map()]) ::
          {:ok, State.t()} | {:error, {non_neg_integer(), reason() | :empty}}
  def verify_chain([]), do: {:error, {0, :empty}}

  def verify_chain([first | rest]) do
    with {:ok, state} <- at(0, begin(first)) do
      rest
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, state}, &step/2)
    end
  end

  def verify_chain(_entries), do: {:error, {0, {:invalid_field, "entries"}}}

  defp step({entry, index}, {:ok, state}) do
    case at(index, extend(state, entry)) do
      {:ok, state} -> {:cont, {:ok, state}}
      error -> {:halt, error}
    end
  end

  defp at(_index, {:ok, _state} = ok), do: ok
  defp at(index, {:error, reason}), do: {:error, {index, reason}}

  @doc """
  Apply one more entry to a verified state: the check a directory makes
  before it appends, and the step `verify_chain/1` repeats.
  """
  @spec extend(State.t(), Entry.t() | map()) :: {:ok, State.t()} | {:error, reason()}
  def extend(%State{} = state, entry) do
    with {:ok, entry} <- read(entry),
         :ok <- later(entry),
         :ok <- link(entry, state),
         :ok <- authorized(entry, state),
         :ok <- signed(entry, signer_key(entry.signer, state), state.directory),
         {:ok, state} <- apply_entry(entry, state) do
      {:ok, %{state | head: hash(entry), seq: entry.seq}}
    end
  end

  defp begin(entry) do
    with {:ok, entry} <- read(entry),
         :ok <- first(entry),
         recovery = Enum.find(entry.recovery, &(recovery_signer(&1) == entry.signer)),
         :ok <- signed(entry, recovery && {:recovery, recovery}, entry.directory) do
      {:ok,
       %State{
         identifier: identifier(entry),
         directory: entry.directory,
         head: hash(entry),
         seq: 0,
         keys: [],
         recovery: entry.recovery
       }}
    end
  end

  # A struct is re-read from its map, so a hand-built one is held to the
  # same shape as a decoded one.
  defp read(%Entry{} = entry), do: entry |> Entry.encode() |> Entry.decode()
  defp read(map), do: Entry.decode(map)

  defp first(%Entry{kind: :genesis}), do: :ok
  defp first(%Entry{}), do: {:error, :not_genesis}

  defp later(%Entry{kind: :genesis}), do: {:error, :unexpected_genesis}
  defp later(%Entry{}), do: :ok

  defp link(%Entry{prev: head, seq: seq}, %State{head: head, seq: at}) when seq == at + 1,
    do: :ok

  defp link(%Entry{}, %State{}), do: {:error, :broken_link}

  # Which signers each kind takes: a code alone recovers or adds a code,
  # and a key never removes itself.
  defp authorized(%Entry{kind: kind, signer: "recovery:" <> _ = signer}, state)
       when kind in [:add_key, :remove_key, :recover, :add_recovery],
       do: listed(State.recovery_key(state, signer))

  defp authorized(%Entry{kind: :add_key, signer: kid}, state), do: listed(State.key(state, kid))

  defp authorized(%Entry{kind: :remove_key, signer: kid, kid: removed}, state)
       when kid != removed,
       do: listed(State.key(state, kid))

  defp authorized(%Entry{}, _state), do: {:error, :wrong_signer}

  defp listed(nil), do: {:error, :wrong_signer}
  defp listed(_key), do: :ok

  defp signer_key("recovery:" <> _ = signer, state) do
    case State.recovery_key(state, signer) do
      nil -> nil
      pub -> {:recovery, pub}
    end
  end

  defp signer_key(kid, state) do
    case State.key(state, kid) do
      nil -> nil
      key -> {:key, key}
    end
  end

  defp signed(%Entry{sig: sig} = entry, {:recovery, pub}, _directory) when is_binary(sig),
    do: ed25519(entry, sig, pub)

  defp signed(%Entry{sig: sig} = entry, {:key, %Key{alg: :ed25519, pub: pub}}, _directory)
       when is_binary(sig),
       do: ed25519(entry, sig, pub)

  defp signed(%Entry{sig: %{} = sig} = entry, {:key, %Key{alg: :es256, pub: pub}}, directory) do
    {origin, host} = Encoding.directory_origin(directory)

    case WebAuthn.verify(sig, pub, challenge(entry), origin, host) do
      :ok -> :ok
      {:error, _reason} -> {:error, :wrong_signer}
    end
  end

  defp signed(_entry, _signer, _directory), do: {:error, :wrong_signer}

  defp ed25519(entry, sig, pub) do
    if :crypto.verify(:eddsa, :none, signing_bytes(entry), sig, [pub, :ed25519]),
      do: :ok,
      else: {:error, :wrong_signer}
  end

  defp apply_entry(%Entry{kind: :add_key, key: key}, state) do
    if State.key(state, key.kid),
      do: {:error, :duplicate_key},
      else: {:ok, %{state | keys: state.keys ++ [key]}}
  end

  defp apply_entry(%Entry{kind: :remove_key, kid: kid}, state) do
    if State.key(state, kid),
      do: {:ok, %{state | keys: Enum.reject(state.keys, &(&1.kid == kid))}},
      else: {:error, {:invalid_field, "kid"}}
  end

  defp apply_entry(%Entry{kind: :recover, keys: keys, recovery: recovery}, state) do
    if length(Enum.uniq_by(keys, & &1.kid)) == length(keys),
      do: {:ok, %{state | keys: keys, recovery: recovery}},
      else: {:error, :duplicate_key}
  end

  defp apply_entry(%Entry{kind: :add_recovery, recovery: recovery}, state) do
    if MapSet.subset?(MapSet.new(state.recovery), MapSet.new(recovery)) and
         length(recovery) > length(state.recovery),
       do: {:ok, %{state | recovery: recovery}},
       else: {:error, {:invalid_field, "recovery"}}
  end
end
