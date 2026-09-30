# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.CyfrDoor do
  @moduledoc """
  The `cyfr` door: a person from another home presents an assertion
  their own home signed over this home's challenge, audience and pending
  carry. This home checks the carried genesis against the identifier,
  resolves its directory fresh, verifies the chain and the assertion
  under the current live key, and admits with provider `cyfr` and the
  identifier as subject, under its own standing rules.

  It holds no function yet: this door admits no one.
  """
end
