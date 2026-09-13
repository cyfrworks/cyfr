# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.HealthProbe do
  @moduledoc """
  Where the readiness probe writes — under the `system/` global root.

  Shares the storage probe path between the readiness controller and
  the retention scheduler that reclaims stranded probe files.
  """

  @doc "The probe directory as storage path segments."
  @spec dir() :: [String.t()]
  def dir, do: ["system", "health"]
end
