# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Opus.AuthorityShimTest do
  @moduledoc """
  The migration's sanctioned-shim deletion gate: `Opus.AuthorityShim`
  held every dual-dispatch allowance the ingress cutover needed, and its
  moduledoc promised a test would assert it no longer loads. This is
  that test — if the module reappears, someone rebuilt a legacy
  allowance and did it past a gate that says so.
  """

  use ExUnit.Case, async: true

  test "the shim no longer exists" do
    refute Code.ensure_loaded?(Opus.AuthorityShim)
  end
end
