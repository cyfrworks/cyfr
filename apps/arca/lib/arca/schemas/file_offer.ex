# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.FileOffer do
  @moduledoc """
  One file of a person's offer to another (`Arca.FileOffers`), in the
  SENDER's athanor: the files of one offer share `offer_id`, and each row
  names the file's name, digest and size in the snapshot under the
  sender's `payloads/offers/<offer id>/`. `status` is `offered`,
  `accepted`, `declined`, `withdrawn` or `expired`, and every row of an
  offer moves together.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{}

  @statuses ~w(offered accepted declined withdrawn expired)

  schema "file_offers" do
    field :athanor_id, :string
    field :offer_id, :string
    field :sender_user_id, :string
    field :recipient_user_id, :string
    field :filename, :string
    field :digest, :string
    field :size, :integer
    field :status, :string, default: "offered"
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The states an offer moves through."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end
