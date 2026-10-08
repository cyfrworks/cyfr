# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.FileOffer do
  @moduledoc """
  A file offer moved, on the global per-person `Cyfr.Bus.file_offers/1`
  of each person it concerns: an offer's transitions reach its sender and
  its recipient, and a receipt that landed, or that the sweep failed,
  reaches its recipient alone. One message per file, as the store
  announces them. The kind is
  what happened; `offer_id` names the offer, `from_user_id` its sender
  and `filename` the file, and nothing of the file travels: no size,
  digest, path or byte. A page reads the offers again through
  `file/offers`, under its own session, and learns only what that session
  may.
  """

  alias Cyfr.Bus.Payload

  @kinds [:offered, :accepted, :declined, :withdrawn, :expired, :failed, :landed]

  @enforce_keys [:kind, :offer_id, :from_user_id, :filename]
  defstruct [:kind, :offer_id, :from_user_id, :filename]

  @type kind ::
          :offered | :accepted | :declined | :withdrawn | :expired | :failed | :landed

  @type t :: %__MODULE__{
          kind: kind(),
          offer_id: String.t(),
          from_user_id: String.t(),
          filename: String.t()
        }

  @doc "The closed union of what this payload says happened."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The change `kind` of the file `filename` of the offer `offer_id`, which
  `from_user_id` sent. A kind outside `kinds/0`, or an id or a filename
  that is not a non-empty string, raises.
  """
  @spec new(kind(), String.t(), String.t(), String.t()) :: t()
  def new(kind, offer_id, from_user_id, filename) do
    %__MODULE__{
      kind: Payload.kind!(__MODULE__, kind, @kinds),
      offer_id: named!(:offer_id, offer_id),
      from_user_id: named!(:from_user_id, from_user_id),
      filename: named!(:filename, filename)
    }
  end

  defp named!(_field, value) when is_binary(value) and value != "", do: value

  defp named!(field, value) do
    raise ArgumentError,
          "a file offer's #{field} is a non-empty string, got #{Prima.LoggerContext.shape(value)}"
  end
end
