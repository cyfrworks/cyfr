# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.SettingsTest do
  @moduledoc """
  `Cyfr.Test.Settings` with no sandbox owner: a `reset/1` that checks out
  a connection of its own leaves the settings cache true to the store once
  the test has ended and its checkout is rolled back.

  The store's committed row is the test's own, made outside every sandbox
  and put back as it was found; the check runs in an `on_exit`, after the
  rollback, outside every sandbox.
  """

  use ExUnit.Case, async: false

  alias Arca.PlatformSettings, as: Store
  alias Ecto.Adapters.SQL.Sandbox

  @key "max_athanors"

  test "a reset on a checkout of its own is not read from the cache once the test has ended" do
    saved = Sandbox.unboxed_run(Arca.Repo, fn -> Store.get(@key) end)

    on_exit(fn ->
      Sandbox.unboxed_run(Arca.Repo, fn ->
        after_rollback = Store.effective(@key)
        {:ok, %{revision: revision}} = Store.all()

        case saved do
          {:ok, row} -> {:ok, _} = Store.put(@key, row.value, revision, row.set_by)
          {:error, :not_found} -> {:ok, _} = Store.delete(@key, revision)
        end

        Store.invalidate(@key)
        assert after_rollback == {:ok, 73}
      end)
    end)

    Sandbox.unboxed_run(Arca.Repo, fn ->
      {:ok, %{revision: revision}} = Store.all()
      {:ok, _next} = Store.put(@key, 73, revision, "test")
    end)

    :ok = Cyfr.Test.Settings.reset(@key)
    assert Store.effective(@key) == {:ok, 10_000}
  end
end
