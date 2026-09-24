# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Tinctures do
  @moduledoc """
  A tincture invocation started or stopped, or the athanor's tinctures
  changed, on `Cyfr.Bus.tinctures/1`. `changed` is the component domain's
  projection reconciler announcing a replacement that touched a tincture
  after it committed. `error` is bounded.
  """

  alias Cyfr.Bus.Payload

  @kinds [:invoke_started, :invoke_stopped, :changed]
  @fields [:request_id, :tincture_ref, :reference, :status, :error]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind | @fields]

  @type kind :: :invoke_started | :invoke_stopped | :changed

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          request_id: String.t() | nil,
          tincture_ref: String.t() | nil,
          reference: String.t() | nil,
          status: atom() | nil,
          error: atom() | String.t() | nil
        }

  @doc "The closed union of what this payload says happened."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The payload for `actor`'s athanor. A kind outside `kinds/0` or a field
  this struct does not declare raises.
  `error` is projected through `Cyfr.Bus.bounded_reason/1`.
  """
  @spec new(Cyfr.Actor.t(), kind(), map() | keyword()) :: t()
  def new(%Cyfr.Actor{} = actor, kind, fields \\ %{}) do
    fields = Map.new(fields)

    fields =
      Enum.reduce([:error], fields, fn key, acc ->
        if Map.has_key?(acc, key),
          do: Map.update!(acc, key, &Cyfr.Bus.bounded_reason/1),
          else: acc
      end)

    Payload.build(__MODULE__, @fields, fields, %{
      athanor_id: Payload.athanor!(actor),
      kind: Payload.kind!(__MODULE__, kind, @kinds)
    })
  end
end
