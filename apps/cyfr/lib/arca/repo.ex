# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo do
  use Ecto.Repo,
    otp_app: :cyfr,
    adapter: Application.compile_env(:cyfr, :repo_adapter, Ecto.Adapters.SQLite3)
end