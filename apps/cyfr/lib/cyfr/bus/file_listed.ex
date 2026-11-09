# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.FileListed do
  @moduledoc """
  One item of the person's recent files or waiting offers, or its
  leaving, on the athanor's `Cyfr.Bus.files/1`, for the stream a canvas
  reads (`files.changes`).

    * `file` — a file under `data/` as a committed write left it: `id`
      its path in the athanor's tree (`data/reports/q3.csv`), `name` the
      file's own name, `type` its media type as the download route serves
      it and `changed_at` when its last write or delete settled.
    * `offer` — an offer of files waiting for the person's answer: `id`
      the offer, `name` its first file's name, `type` that file's media
      type, `changed_at` when it was made and `from` its sender's display
      name.
    * `removed` — the item `id` names left the list: the file was
      deleted, or the offer was accepted, declined, withdrawn or expired.
      Every other field is nil.

  The item's own kind is the payload's `kind`, so a file's kind rides as
  `type`. Never a file's contents, a download link, a person's
  identifier or a sender's athanor.
  """

  alias Cyfr.Bus.Payload

  @kinds [:file, :offer, :removed]
  @fields [:id, :name, :type, :changed_at, :from]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind, :revision, :at | @fields]

  @type kind :: :file | :offer | :removed

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          revision: non_neg_integer(),
          at: DateTime.t(),
          id: String.t() | nil,
          name: String.t() | nil,
          type: String.t() | nil,
          changed_at: DateTime.t() | nil,
          from: String.t() | nil
        }

  @doc "The closed union: a recent file, an offer waiting, or an item that left."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The payload for `actor`'s athanor. A kind outside `kinds/0` or a field
  this struct does not declare raises.
  """
  @spec new(Prima.Actor.t(), kind(), map() | keyword()) :: t()
  def new(%Prima.Actor{} = actor, kind, fields \\ %{}) do
    Payload.build(__MODULE__, [:revision, :at | @fields], Payload.stamped(fields), %{
      athanor_id: Payload.athanor!(actor),
      kind: Payload.kind!(__MODULE__, kind, @kinds)
    })
  end
end
