# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ReleaseTest do
  # The release task sees the same migrations the boot path runs; on a
  # current schema there is nothing pending.
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  test "the test database is current — nothing pending" do
    assert Cyfr.Release.pending() == []
  end

  test "migrate/0 on a current schema is a no-op that returns :ok" do
    assert :ok = Cyfr.Release.migrate()
  end
end
