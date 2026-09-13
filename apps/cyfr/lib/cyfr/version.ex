# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Version do
  @moduledoc """
  This build's version, read from the loaded application.

  Reads the running application version through `:application.get_key/2`.
  """

  @doc """
  The running version, e.g. `"0.6.0"`.

  Returns `"unknown"` only before the application is loaded, which in
  practice means tooling rather than a served request.
  """
  @spec current() :: String.t()
  def current do
    case :application.get_key(:cyfr, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      :undefined -> "unknown"
    end
  end
end
