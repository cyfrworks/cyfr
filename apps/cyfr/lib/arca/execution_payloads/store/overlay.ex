# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionPayloads.Store.Overlay do
  @moduledoc """
  The shipped payload store: the athanor's own tree through `Arca`,
  under the overlay's internal-write scope. The `payloads/` root is
  reserved (`Arca.Storage.reserved_roots/0`), so a member's write there
  is refused and only these calls change it.
  """

  @behaviour Arca.ExecutionPayloads.Store

  @impl true
  def put(ctx, segments, bytes),
    do: Arca.Overlay.with_internal_writes(fn -> Arca.put(ctx, segments, bytes) end)

  @impl true
  def get(ctx, segments), do: Arca.get(ctx, segments)

  @impl true
  def delete(ctx, segments),
    do: Arca.Overlay.with_internal_writes(fn -> Arca.delete(ctx, segments) end)
end
