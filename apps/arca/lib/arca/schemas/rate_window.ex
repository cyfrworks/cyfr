# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.RateWindow do
  @moduledoc """
  One bucket's consented invocation rate, shared by every member of the
  cell: the athanor and the component reference (or a platform bucket's
  name) it is claimed under, the current window and the one before it.

  Two adjacent fixed windows rather than a row per request. A claim reads
  `window_start`, `window_ms`, `count` and `prior_count` and admits while

      prior_count * (window_ms - elapsed) / window_ms + count  <  cap

  where `elapsed` is database time since `window_start`. When `elapsed`
  reaches `window_ms` the row rotates: `prior_count` takes `count`,
  `count` starts at one and `window_start` moves forward by one width.
  The estimate never admits more than `cap` in any window of `window_ms`,
  and at a boundary it may refuse a claim a per-request sliding window
  would have admitted — the closed direction for a consented ceiling.

  The cap and the width come from the caller's consent on every claim and
  are not stored as policy; `window_ms` is kept only so the row knows what
  its own counts are counts of. A claim carrying a different width opens a
  new window at its own width rather than rescaling a count that was never
  taken under it.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "rate_windows" do
    field :athanor_id, :string
    field :bucket, :string
    field :window_start, :utc_datetime_usec
    field :window_ms, :integer
    field :count, :integer, default: 0
    field :prior_count, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end
end
