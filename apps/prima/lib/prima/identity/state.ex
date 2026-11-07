# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Identity.State do
  @moduledoc """
  What a verified log answers (`Prima.Identity.verify_chain/1`): the
  identifier, the directory that orders it, `head`, the hash of the last
  entry, and `seq`, its position; the keys listed now, in the order they
  were added, and the recovery set. A relying CYFR keeps it as the verified
  state of the head it last read, so the next suffix verifies against it.
  """

  alias Prima.Identity
  alias Prima.Identity.{Encoding, Key}

  @type t :: %__MODULE__{
          identifier: String.t(),
          directory: String.t(),
          head: String.t(),
          seq: non_neg_integer(),
          keys: [Key.t()],
          recovery: [binary()]
        }

  @enforce_keys [:identifier, :directory, :head, :seq, :keys, :recovery]
  defstruct [:identifier, :directory, :head, :seq, :keys, :recovery]

  @doc "The JSON map of a state."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = state) do
    %{
      "identifier" => state.identifier,
      "directory" => state.directory,
      "head" => state.head,
      "seq" => state.seq,
      "keys" => Enum.map(state.keys, &Key.encode/1),
      "recovery" => Encoding.b64_keys(state.recovery)
    }
  end

  @doc """
  Read a state from its JSON map, as `encode/1` writes it: the state a
  directory stored beside its head, or a CYFR beside the head it cached.
  Every field is held to its spelling and every key to `Prima.Identity.Key`'s.
  """
  @spec decode(term()) :: {:ok, t()} | :error
  def decode(
        %{
          "identifier" => identifier,
          "directory" => directory,
          "head" => head,
          "seq" => seq,
          "keys" => keys,
          "recovery" => recovery
        } = map
      )
      when map_size(map) == 6 and is_list(keys) and is_list(recovery) do
    with true <- Encoding.identifier?(identifier),
         true <- Encoding.directory_url?(directory),
         true <- Encoding.digest?(head),
         true <- Encoding.ms?(seq),
         decoded = Enum.map(keys, &Key.decode/1),
         false <- Enum.member?(decoded, :error),
         {:ok, recovery} <- Encoding.keys(map, "recovery") do
      {:ok,
       %__MODULE__{
         identifier: identifier,
         directory: directory,
         head: head,
         seq: seq,
         keys: Enum.map(decoded, fn {:ok, key} -> key end),
         recovery: recovery
       }}
    else
      _ -> :error
    end
  end

  def decode(_value), do: :error

  @doc "The listed key `kid` names, or nil."
  @spec key(t(), String.t()) :: Key.t() | nil
  def key(%__MODULE__{keys: keys}, kid), do: Enum.find(keys, &(&1.kid == kid))

  @doc "The listed passkey whose credential id is `credential_id`, or nil."
  @spec passkey(t(), binary()) :: Key.t() | nil
  def passkey(%__MODULE__{keys: keys}, credential_id),
    do: Enum.find(keys, &(&1.kind == :passkey and &1.credential_id == credential_id))

  @doc "The recovery public key a `recovery:<kid>` signer names, or nil."
  @spec recovery_key(t(), String.t()) :: binary() | nil
  def recovery_key(%__MODULE__{recovery: recovery}, signer),
    do: Enum.find(recovery, &(Identity.recovery_signer(&1) == signer))
end
