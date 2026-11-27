# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.GuardTableTest do
  @moduledoc """
  The island egress guard's address table
  (`apps/locus/keeper/guard/table_gen.go`) is `Prima.Cidr.address_table/0`,
  the table the control plane's own outbound calls are held to. That it holds
  every range the island must refuse, and what the guard installs of it in
  which order, are the guard's own tests
  (`apps/locus/keeper/guard/rules_test.go`).
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Cyfr.Gen.GuardTable

  test "the guard's address table is Prima.Cidr's" do
    assert File.read!(GuardTable.path()) == GuardTable.render(),
           "table_gen.go does not hold Prima.Cidr.address_table/0 — run `mix cyfr.gen.guard_table`"
  end
end
