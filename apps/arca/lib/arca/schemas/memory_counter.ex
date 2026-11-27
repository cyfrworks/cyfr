# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.MemoryCounter do
  @moduledoc """
  One counter of who used what (`Arca.MemoryRecord`), its athanor's row:
  what the keeper of one endpoint's machine counted for one athanor, kind
  and subject on one UTC day of one boot, at its role's `rev`. `subject`
  is the empty string where the counter has none.
  """

  use Ecto.Schema

  @primary_key false
  @type t :: %__MODULE__{}

  schema "memory_counters" do
    field :athanor_id, :string, primary_key: true
    field :endpoint, :string, primary_key: true
    field :boot, :string, primary_key: true
    field :day, :date, primary_key: true
    field :kind, :string, primary_key: true
    field :subject, :string, primary_key: true
    field :rev, :integer
    field :shown, :string
    field :name, :string
    field :bytes, :integer
    field :mib_ms, :integer
    field :measured_ms, :integer
    field :peak_bytes, :integer
    field :cap, :integer
    field :machine, :integer
    field :either, :integer
  end
end
