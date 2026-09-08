# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuildsDisabledTest do
  # `CYFR_BUILDS=false` is a process-wide setting, so this module owns it
  # for the duration of its tests and hands the previous value back.
  use ExUnit.Case, async: false

  alias Locus.MCP

  setup do
    previous = Application.get_env(:cyfr, :builds_enabled)
    Application.put_env(:cyfr, :builds_enabled, false)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:cyfr, :builds_enabled),
        else: Application.put_env(:cyfr, :builds_enabled, previous)
    end)

    :ok
  end

  test "compile is refused on the one handler every surface reaches" do
    ctx = Sanctum.TestContext.local()

    for args <- [
          %{"action" => "compile", "reference" => "catalyst:local.never-built"},
          %{"action" => "compile", "reference" => "catalyst:local.never-built", "async" => true}
        ] do
      assert {:error, message} = MCP.handle("build", ctx, args)
      assert message =~ "CYFR_BUILDS=false"
    end
  end

  test "the read-only actions still answer" do
    ctx = Sanctum.TestContext.local()
    assert {:ok, %{toolchains: _}} = MCP.handle("build", ctx, %{"action" => "toolchains"})
  end
end
