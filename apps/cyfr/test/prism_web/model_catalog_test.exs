# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ModelCatalogTest do
  # The loader's answer for a context that names no athanor: there is no
  # catalogue to run or to keep, so the caller hears `:unavailable` at
  # once — not a task that raises on the keep and a deadline waited out.
  use ExUnit.Case, async: true

  test "a context with no athanor has no catalogue: unavailable, nothing sent, no deadline" do
    ctx = %{Sanctum.TestContext.local() | athanor_id: nil}

    assert :unavailable = PrismWeb.ModelCatalog.load(ctx)
    refute_received {:list_models_result, _}
    refute_received {:task_timeout, :models}
  end
end
