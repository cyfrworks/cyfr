# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo do
  @moduledoc """
  The one repository.

  Ecto binds its adapter at compile time, which is why `CYFR_DATABASE` is
  parsed into `:arca, :repo_adapter` by a configuration file rather than
  read at runtime. `adapter/0` reports the value the compiler bound, for
  the callers that must branch on it.
  """

  use Ecto.Repo,
    otp_app: :arca,
    # config:compile-runtime-ok — Ecto binds the adapter at compile time;
    # `adapter/0` reports the same value at runtime.
    adapter: Application.compile_env(:arca, :repo_adapter, Ecto.Adapters.SQLite3)

  @doc """
  The adapter this build was compiled against, read at runtime.

  Read from configuration rather than answered as `__adapter__/0`, so a
  caller that branches on it still has two branches to write: the value is
  the deployment's, fixed at compile time, and a build's own adapter is not
  a fact about the code.
  """
  # config:compile-runtime-ok — the same key the adapter above is bound
  # from, read at runtime by the callers that branch on it.
  @spec adapter() :: module()
  def adapter, do: Application.get_env(:arca, :repo_adapter, Ecto.Adapters.SQLite3)

  @doc """
  SQLite busy timeout, used both as the Repo connection option and in the
  boot-time PRAGMA — one constant so the two mechanisms stay in step.
  """
  @spec busy_timeout_ms() :: pos_integer()
  def busy_timeout_ms, do: 5_000

  @doc "Where this application's migrations live."
  @spec migrations_path() :: String.t()
  def migrations_path, do: Application.app_dir(:arca, "priv/repo/migrations")
end
