# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.OpsGenCliTaskTest do
  @moduledoc """
  `mix ops.gen.cli` takes no argument or `--check`, and refuses any other
  before it renders or writes anything.
  """

  use ExUnit.Case, async: true

  @catalog Path.expand("../../../codex/internal/ops/catalog_gen.go", __DIR__)

  test "an argument it does not take is refused, and the catalog is left as it was" do
    before = File.read!(@catalog)

    for args <- [["--chek"], ["--check", "extra"], ["catalog_gen.go"]] do
      assert_raise Mix.Error, "usage: mix ops.gen.cli [--check]", fn ->
        Mix.Tasks.Ops.Gen.Cli.run(args)
      end
    end

    assert File.read!(@catalog) == before
  end
end
