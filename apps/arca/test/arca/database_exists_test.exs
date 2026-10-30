# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DatabaseExistsTest do
  @moduledoc """
  `Arca.database_exists/1` asks this build's adapter, without starting a
  repository, whether the database a configuration names exists: the
  suite's own does, and one it never made does not, and asking makes
  nothing.
  """

  use ExUnit.Case, async: true

  test "the suite's database exists, and a database never made does not" do
    absent = "arca_absent_#{System.unique_integer([:positive])}"
    config = Arca.Repo.config()

    case Arca.adapter_facts().adapter do
      :sqlite ->
        assert Arca.database_exists(database: config[:database]) == {:ok, true}

        path = Path.join(System.tmp_dir!(), absent <> ".db")
        assert Arca.database_exists(database: path) == {:ok, false}
        refute File.exists?(path)

      :postgres ->
        server =
          "postgres://#{config[:username]}:#{config[:password]}@#{config[:hostname]}:" <>
            "#{config[:port] || 5432}/"

        assert Arca.database_exists(url: server <> config[:database]) == {:ok, true}
        assert Arca.database_exists(url: server <> absent) == {:ok, false}
        # Asking made nothing: it is still absent.
        assert Arca.database_exists(url: server <> absent) == {:ok, false}
    end
  end
end
