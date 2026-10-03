# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.FileReceipt do
  @moduledoc """
  One accepted file, in the RECIPIENT's athanor (`Arca.FileOffers`): the
  transfer's custody copy, at `custody_path` under
  `payloads/receipts/<offer id>/<attempt>/` (the acceptance's own
  directory), and its publication into
  `<folder>/<offer id>[-<n>]/<filename>`.

  `status` is `received`, `published`, `completed` or `failed`.
  `attempt_path` is the path the current attempt writes, recorded before
  the write, with `attempt_state` `chosen` (not yet sent) or `issued`
  (sent at least once). `issued_paths` (a JSON array) is every path a
  write was ever sent to, and `ever_issued` whether one ever was; neither
  shrinks. `completing_by` and `completing_until` are the claim of the
  completer working on the row.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{}

  @statuses ~w(received published completed failed)

  schema "file_receipts" do
    field :athanor_id, :string
    field :offer_id, :string
    field :sender_user_id, :string
    field :recipient_user_id, :string
    field :filename, :string
    field :digest, :string
    field :size, :integer
    field :folder, :string
    field :custody_path, :string
    field :status, :string, default: "received"
    field :attempt_path, :string
    field :attempt_state, :string
    field :issued_paths, :string, default: "[]"
    field :ever_issued, :boolean, default: false
    field :completing_by, :string
    field :completing_until, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The states a receipt moves through."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end
