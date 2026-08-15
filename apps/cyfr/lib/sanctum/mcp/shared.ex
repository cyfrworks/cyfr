# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.Shared do
  @moduledoc """
  Helpers shared across the Sanctum MCP tool modules
  (`Sanctum.MCP` facade and the per-tool modules).

  These are moved verbatim from the original `Sanctum.MCP` module to
  preserve behaviour exactly; only their visibility changed from `defp`
  to `def` so the tool modules can call them.
  """


  def format_permissions(permissions) do
    permissions
    |> MapSet.to_list()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

end
