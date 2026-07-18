# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Application do
  @moduledoc false

  @doc false
  # The registry is always cyfr.run unless CYFR_REGISTRY_URL /
  # CYFR_OCI_REGISTRY_URL point at a custom cyfr.run-compatible host. Both are
  # freely configurable; the defaults are applied in `config/runtime.exs`, so
  # there is nothing to validate or pin here. Retained as a no-op hook for the
  # boot sequence.
  def validate_registry_config!, do: :ok
end
