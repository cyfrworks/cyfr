# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.HealthProbe do
  @moduledoc """
  Where the readiness probe writes — under the `system/` global root.

  One spelling, in the glue namespace, because two planes consume it: the
  web controller (`EmissaryWeb.HealthController`) writes the probe, and
  the retention scheduler reclaims stranded probe files. The scheduler
  asking the CONTROLLER for the path was glue reaching upward into the
  web layer for three list elements.
  """

  @doc "The probe directory as storage path segments."
  @spec dir() :: [String.t()]
  def dir, do: ["system", "health"]
end
