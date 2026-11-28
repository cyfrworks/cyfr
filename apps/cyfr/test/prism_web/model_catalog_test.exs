# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ModelCatalogTest do
  # The loader's answer for a context that names no athanor: there is no
  # catalogue to run or to keep, so the caller hears `:unavailable` at
  # once — not a task that raises on the keep and a deadline waited out.
  use ExUnit.Case, async: true

  setup do
    Arca.Cache.init()
    :ok
  end

  test "a context with no athanor has no catalogue: unavailable, nothing sent, no deadline" do
    ctx = %{Sanctum.TestContext.local() | athanor_id: nil}

    assert :unavailable = PrismWeb.ModelCatalog.load(ctx)
    refute_received {:list_models_result, _tag, _result}
    refute_received {:task_timeout, :models}
  end

  defp athanor, do: "ath_catalog_#{System.unique_integer([:positive])}"

  test "a caller's number for a load comes back with its answer" do
    id = athanor()
    ctx = %{Sanctum.TestContext.local() | athanor_id: id}
    :ok = PrismWeb.ModelCatalog.remember(id, %{"models" => %{"m" => ["one"]}})

    assert :ok = PrismWeb.ModelCatalog.load(ctx, 7)
    assert_received {:list_models_result, _tag, 7, {:ok, %{"models" => %{"m" => ["one"]}}}}

    assert :ok = PrismWeb.ModelCatalog.load(ctx)
    assert_received {:list_models_result, _tag, {:ok, %{"models" => %{"m" => ["one"]}}}}
  end

  # A asked under the working key, the key rotated, A's list arriving
  # after: a page opened then asks again and does not read A's list.
  test "a listing whose run began before a forget is not kept; one begun after is" do
    id = athanor()
    kept = fn -> Arca.Cache.get({:model_catalog, id}) end

    began = PrismWeb.ModelCatalog.began(id)
    :ok = PrismWeb.ModelCatalog.forget(id)
    :ok = PrismWeb.ModelCatalog.remember(id, %{"models" => %{"m" => ["old key's"]}}, began)
    assert kept.() == :miss

    began = PrismWeb.ModelCatalog.began(id)
    :ok = PrismWeb.ModelCatalog.remember(id, %{"models" => %{"m" => ["new key's"]}}, began)
    assert kept.() == {:ok, %{"models" => %{"m" => ["new key's"]}}}
  end
end
