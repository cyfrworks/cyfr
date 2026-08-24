# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo do
  use Ecto.Repo,
    otp_app: :cyfr,
    # config:compile-runtime-ok — Ecto binds the adapter at compile time;
    # `Cyfr.RuntimeConfig.repo_adapter/0` reports the same value at runtime.
    adapter: Application.compile_env(:cyfr, :repo_adapter, Ecto.Adapters.SQLite3)
end
