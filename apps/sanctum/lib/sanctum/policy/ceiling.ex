# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Policy.Ceiling do
  @moduledoc """
  The platform ceiling this instance enforces: `Prima.Limits.Ceiling`'s
  compiled values lowered by the operator's `:sanctum, :platform_ceiling`
  config, which may lower a field and never raise it.
  """

  @doc "The platform ceiling (absolute infrastructure max), with config overrides applied."
  @spec platform_ceiling() :: map()
  def platform_ceiling,
    do: Prima.Limits.Ceiling.lowered(Application.get_env(:sanctum, :platform_ceiling, %{}))
end
