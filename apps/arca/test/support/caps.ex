# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.Caps do
  @moduledoc """
  The cap port's stand-in for this suite: it admits.

  The ceilings are the tenancy domain's, one app above, and Arca cannot
  implement them — that is what the port is for. The double exists so a
  capped write reaches its query at all; a case about a refusal needs both
  sides of the port and lives where both are (`apps/cyfr/test/arca`).

  It runs no count, which is what a server with the cap unconfigured does:
  the count is only paid for while a ceiling is set.
  """

  @behaviour Prima.Caps

  @impl Prima.Caps
  def check_counted(%Prima.Actor{}, _key, count) when is_function(count, 0), do: :ok

  @impl Prima.Caps
  def check_storage(%Prima.Actor{}, incoming) when is_integer(incoming) and incoming >= 0, do: :ok
end
