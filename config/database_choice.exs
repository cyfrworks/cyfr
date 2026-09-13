# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# Shared compile-time CYFR_DATABASE parser. Ecto adapters cannot change at runtime.
defmodule Cyfr.ConfigEnv.DatabaseChoice do
  def choice! do
    case String.downcase(System.get_env("CYFR_DATABASE", "sqlite")) do
      "sqlite" -> :sqlite
      "postgres" -> :postgres
      other -> raise "Unknown CYFR_DATABASE=#{other}; expected \"sqlite\" or \"postgres\""
    end
  end
end
