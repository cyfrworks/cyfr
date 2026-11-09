# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.SystemStatus do
  @moduledoc """
  How the person's CYFR stands, on the athanor's `Cyfr.Bus.system/1`,
  for the stream a canvas reads (`system.changes`): one whole status,
  `changed` whenever one of its facts moves.

    * `health` — `ok`, `degraded` (a service does not answer) or
      `low_storage` (the CYFR's storage reserve is spent, so it takes in
      no new bytes).
    * `storage_used` and `storage_cap` — the athanor's stored bytes and
      its cap, nil when no cap is set.
    * `model_connected` — AQUA's own brain can answer.
    * `crew_ready` and `crew_total` — the crew members whose brain can
      answer, of all of them.
    * `version` — the running CYFR's version.
    * `update_available` — the release channel `cyfr update` reads lists
      a release newer than this one, nil while it has not been read.

  Never a key, an address, a service's own message or anything of
  another athanor.
  """

  alias Cyfr.Bus.Payload

  @kinds [:changed]
  @fields [
    :health,
    :storage_used,
    :storage_cap,
    :model_connected,
    :crew_ready,
    :crew_total,
    :version,
    :update_available
  ]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind | @fields]

  @type kind :: :changed

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          health: String.t() | nil,
          storage_used: non_neg_integer() | nil,
          storage_cap: pos_integer() | nil,
          model_connected: boolean() | nil,
          crew_ready: non_neg_integer() | nil,
          crew_total: non_neg_integer() | nil,
          version: String.t() | nil,
          update_available: boolean() | nil
        }

  @doc "The closed union: the status as it now stands."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The fields of a status, in the order the stream projects them."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc """
  The payload for `actor`'s athanor. A kind outside `kinds/0` or a field
  this struct does not declare raises.
  """
  @spec new(Prima.Actor.t(), kind(), map() | keyword()) :: t()
  def new(%Prima.Actor{} = actor, kind, fields \\ %{}) do
    Payload.build(__MODULE__, @fields, fields, %{
      athanor_id: Payload.athanor!(actor),
      kind: Payload.kind!(__MODULE__, kind, @kinds)
    })
  end
end
