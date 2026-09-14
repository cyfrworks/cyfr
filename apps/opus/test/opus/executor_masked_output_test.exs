# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutorMaskedOutputTest do
  use ExUnit.Case, async: true

  describe "what the executor hands back" do
    # A successful run needs a real Component Model binary, which the suite
    # has no fixture for (`math.wasm` is a core module and fails at
    # instantiation by design), so the value returned on the success path is
    # not reachable from a test. The invariant is still load-bearing — the
    # masked output is what reaches MCP clients, parent formulas and public
    # tincture callers — so it is pinned at the source, the way
    # `Cyfr.IngressInventoryTest` pins the ingress roster.
    test "finalize_execution returns the masked output, never the raw one" do
      body = finalize_execution_body()

      assert body =~ "output: masked_output",
             "finalize_execution/3 must return the masked output"

      refute body =~ ~r/\boutput: output\b/,
             "finalize_execution/3 returned the raw component output — a component " <>
               "that echoes its credential would leak it to every caller, while only " <>
               "the audit row stayed redacted"
    end

    defp finalize_execution_body do
      source =
        [__DIR__, "..", "..", "lib", "opus", "executor.ex"]
        |> Path.join()
        |> Path.expand()
        |> File.read!()

      [_, body] = String.split(source, "defp finalize_execution(", parts: 2)
      [body, _] = String.split(body, "\n  defp ", parts: 2)
      body
    end
  end
end
