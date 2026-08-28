# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# The one parse of CYFR_DATABASE, shared by config.exs and test.exs via
# Code.require_file — config files run before the apps compile, so this
# cannot live in Cyfr.RuntimeConfig with the other resolvers. The adapter
# is a build-time choice: Ecto cannot swap adapters at runtime.
defmodule Cyfr.ConfigEnv.DatabaseChoice do
  def choice! do
    case String.downcase(System.get_env("CYFR_DATABASE", "sqlite")) do
      "sqlite" -> :sqlite
      "postgres" -> :postgres
      other -> raise "Unknown CYFR_DATABASE=#{other}; expected \"sqlite\" or \"postgres\""
    end
  end
end
