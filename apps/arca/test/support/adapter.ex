# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.Adapter do
  @moduledoc """
  The database adapter this test build runs on, for the tests that differ
  by adapter.

  A test that runs on one adapter only carries `@tag :postgres` or
  `@tag :sqlite` (or the `@moduletag` or `@describetag` form), and each
  database app's `test_helper.exs` excludes the other adapter's tag with
  `exclusions/0`, so the run reports such a test as excluded, never as
  passed. A test that asserts differently per adapter branches in its body
  on `postgres?/0` or `sqlite?/0`; none defines its own, none compiles its
  body out on an adapter attribute, and none skips itself on the adapter.

  The adapter is the build's (`CYFR_DATABASE`, compiled into
  `:arca, :repo_adapter`), so a build path and the runner that chose it
  cannot disagree.
  """

  @doc "Whether this build runs on PostgreSQL."
  @spec postgres?() :: boolean()
  def postgres?, do: Arca.Repo.adapter() == Ecto.Adapters.Postgres

  @doc "Whether this build runs on SQLite."
  @spec sqlite?() :: boolean()
  def sqlite?, do: Arca.Repo.adapter() == Ecto.Adapters.SQLite3

  @doc """
  The tag of the adapter this build does not run on, for the helpers'
  exclusions: `[:postgres]` on SQLite and `[:sqlite]` on PostgreSQL.
  """
  @spec exclusions() :: [:postgres | :sqlite]
  def exclusions, do: if(postgres?(), do: [:sqlite], else: [:postgres])
end
