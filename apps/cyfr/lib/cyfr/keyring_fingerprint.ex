# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.KeyringFingerprint do
  @moduledoc """
  Which keyring this database was sealed with, checked at every boot.

  The at-rest cipher labels every envelope with its key's label, and the
  derived zero-config key and an explicit keyring's primary can both be
  called `default`. So an explicit `CYFR_CRYPTO_KEYRING` that went missing
  — unset, blanked by a bad `.env`, dropped by a deploy template — was
  silently replaced by a different key under the same label: rows sealed
  before failed to open while new writes succeeded, and the athanor forked
  into two key generations with no boundary event and nothing to say so.

  The fingerprint is of the PRIMARY only — `sha256("cyfr-keyring-fingerprint|"
  <> label <> "|" <> key)` — so a keyring that gains a decrypt-only
  secondary reads as a rotation in progress, not a fork. It is recorded on
  first boot and compared on every later one; a mismatch refuses the boot.

  Accepting a different keyring is deliberate and named: set
  `CYFR_CRYPTO_KEYRING_FINGERPRINT_ACCEPT` to the fingerprint this boot
  reports, for one boot. Accepting records the new keyring; it does not
  restore decryptability. Rows sealed under a label the new keyring does
  not carry stay unreadable, which is why a rotation keeps the old label
  among `keys`, boots with the flag, and re-seals every row under the new
  primary (`Cyfr.Release.rotate_cipher_keys/1`) before the old label is dropped.
  """

  require Logger

  @key "crypto_keyring_fingerprint"
  @accept_var "CYFR_CRYPTO_KEYRING_FINGERPRINT_ACCEPT"

  @type keyring :: %{primary: String.t(), keys: %{String.t() => binary()}}

  @doc "The fingerprint of a keyring's primary key."
  @spec compute(keyring()) :: String.t()
  def compute(%{primary: label, keys: keys}) when is_binary(label) and is_map(keys) do
    Cyfr.Digest.sha256_hex("cyfr-keyring-fingerprint|" <> label <> "|" <> Map.fetch!(keys, label))
  end

  @doc """
  Compare this boot's keyring with the one the database recorded.

    * `:ok` — same primary as recorded.
    * `{:recorded, fp}` — first boot; the fingerprint is now on record.
    * `{:accepted, fp, previous}` — a different primary, accepted by the
      operator naming exactly this fingerprint.
    * `{:error, message}` — a different primary nobody accepted, or a
      store that cannot answer. The message is the boot refusal.
  """
  @spec verify(keyring(), String.t() | nil) ::
          :ok
          | {:recorded, String.t()}
          | {:accepted, String.t(), String.t()}
          | {:error, String.t()}
  def verify(keyring, accept), do: verify(keyring, accept, 2)

  defp verify(_keyring, _accept, 0),
    do:
      {:error,
       "[Cyfr] FATAL: the keyring fingerprint row changed underneath this boot twice; another boot is racing it"}

  defp verify(keyring, accept, attempts) do
    fingerprint = compute(keyring)

    case Arca.ServerMetaStorage.get(@key) do
      {:ok, ^fingerprint} ->
        :ok

      {:error, :not_found} ->
        case Arca.ServerMetaStorage.put_new(@key, fingerprint) do
          {:ok, :recorded} -> {:recorded, fingerprint}
          {:error, :exists} -> verify(keyring, accept, attempts - 1)
          {:error, reason} -> {:error, store_refusal(reason)}
        end

      {:ok, previous} ->
        if accept == fingerprint do
          case Arca.ServerMetaStorage.compare_and_put(@key, previous, fingerprint) do
            :ok -> {:accepted, fingerprint, previous}
            {:error, :stale} -> verify(keyring, accept, attempts - 1)
            {:error, reason} -> {:error, store_refusal(reason)}
          end
        else
          {:error, mismatch_refusal(fingerprint, previous, accept)}
        end

      {:error, reason} ->
        {:error, store_refusal(reason)}
    end
  end

  @doc "`verify/2`, raising the refusal and logging the rest."
  @spec verify!(keyring(), String.t() | nil) :: :ok
  def verify!(keyring, accept) do
    case verify(keyring, accept) do
      :ok ->
        :ok

      {:recorded, fingerprint} ->
        Logger.info("[Cyfr] Recorded the crypto keyring fingerprint (#{fingerprint}).")
        :ok

      {:accepted, fingerprint, previous} ->
        Logger.warning(
          "[Cyfr] Accepted a different crypto keyring (#{fingerprint}, previously #{previous}). " <>
            "Rows sealed under a label this keyring does not carry will not open; re-seal with " <>
            "Cyfr.Release.rotate_cipher_keys/1 and then unset #{@accept_var}."
        )

        :ok

      {:error, message} ->
        raise message
    end
  end

  defp mismatch_refusal(fingerprint, previous, accept) do
    accept_note =
      case accept do
        nil -> ""
        other -> " #{@accept_var} is set to #{inspect(other)}, which names neither."
      end

    "[Cyfr] FATAL: the crypto keyring is not the one this database was sealed with — " <>
      "recorded fingerprint #{previous}, this boot's #{fingerprint}.#{accept_note} " <>
      "An explicit CYFR_CRYPTO_KEYRING that went missing derives a different key under the same " <>
      "label, and rows sealed before would fail to open while new writes succeed. Restore the " <>
      "keyring, or — for a deliberate rotation that keeps the old label among its keys — set " <>
      "#{@accept_var}=#{fingerprint} for one boot, then re-seal every row " <>
      "(Cyfr.Release.rotate_cipher_keys/1). Accepting does not restore " <>
      "decryptability."
  end

  defmodule Check do
    @moduledoc false
    # The boot step: `verify!/2` against the resolved keyring, then `:ignore`
    # — like `Cyfr.Bootstrap`, so the supervisor only proceeds once the
    # answer is in and no process lingers.
    use GenServer

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts) do
      Cyfr.KeyringFingerprint.verify!(
        Application.fetch_env!(:cyfr, :crypto_keyring),
        Application.get_env(:cyfr, :crypto_keyring_fingerprint_accept)
      )

      :ignore
    end
  end

  defp store_refusal(reason) do
    "[Cyfr] FATAL: the keyring fingerprint could not be read or recorded (#{inspect(reason)}); " <>
      "refusing to boot rather than seal rows under an unverified key."
  end
end
