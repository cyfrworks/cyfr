# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ToolErrorRenderersTest do
  @moduledoc """
  One refusal, one sentence, whichever surface renders it.

  `Emissary.MCP.ToolError`'s moduledoc names the three consumers that must
  agree: the wire (`Emissary.MCP.Router`), the console
  (`PrismWeb.MCPHelpers`) and the in-chain guest view
  (`Opus.FormulaHandler`). `ToolRegistry` mints a fourth vocabulary of its own
  for a crashed, exited or timed-out tool — and only the router knew it. The
  console showed "The request failed — try again." for all three, losing the
  timeout-vs-crash distinction, and the guest got Elixir term syntax.
  """
  use ExUnit.Case, async: true

  alias Emissary.MCP.ToolError

  @crash_vocabulary [
    {:crashed, "Tool x crashed: boom"},
    {:exit, "Tool x exited unexpectedly"},
    {:timeout, "Tool x timed out after 300000ms"}
  ]

  describe "the crash vocabulary" do
    test "is part of the typed roster" do
      for reason <- @crash_vocabulary do
        assert ToolError.reason?(reason), "#{inspect(reason)} is not recognised"
        assert is_binary(ToolError.message(reason))
      end
    end

    test "renders the same sentence on all three surfaces" do
      for reason <- @crash_vocabulary do
        expected = ToolError.message(reason)

        assert PrismWeb.MCPHelpers.error_message(reason) == expected,
               "the console disagrees about #{inspect(reason)}"

        assert Opus.FormulaHandler.render_reason(reason) == expected,
               "the guest view disagrees about #{inspect(reason)}"
      end
    end

    test "keeps the distinction the console used to lose" do
      timeout = PrismWeb.MCPHelpers.error_message({:timeout, "Tool x timed out after 1ms"})
      crash = PrismWeb.MCPHelpers.error_message({:crashed, "Tool x crashed: boom"})

      assert timeout =~ "timed out"
      assert crash =~ "crashed"
      refute timeout == crash
    end
  end

  describe "the guest never sees an internal term" do
    test "an unknown reason renders as a generic sentence, not inspect output" do
      rendered = Opus.FormulaHandler.render_reason({:some_internal, %{"secret" => "leak"}})

      refute rendered =~ "secret"
      refute rendered =~ "leak"
      refute rendered =~ "%{"
    end

    test "a crafted binary still passes through" do
      assert Opus.FormulaHandler.render_reason("No provider found for scheme ftp") ==
               "No provider found for scheme ftp"
    end

    test "the other typed vocabularies render through their own module" do
      assert Opus.FormulaHandler.render_reason({:not_found, "component", "x"}) ==
               ToolError.message({:not_found, "component", "x"})

      unauthorized = {:missing_permission, :vault_write}

      if Sanctum.Unauthorized.reason?(unauthorized) do
        assert Opus.FormulaHandler.render_reason(unauthorized) ==
                 Sanctum.Unauthorized.message(unauthorized)
      end
    end
  end
end
