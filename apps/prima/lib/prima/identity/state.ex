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
