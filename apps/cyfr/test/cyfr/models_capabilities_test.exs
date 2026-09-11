# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ModelsCapabilitiesTest do
  @moduledoc """
  A planner always has a window: the catalyst's own listing when it
  reports one, the host table by exact catalyst name when it does not,
  the configured default otherwise — and the reading is cached under the
  key it ran with.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Models

  setup do
    Arca.Cache.init()
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp envelope(data), do: %{result: %{"status" => 200, "data" => data}}

  defp runner(described, models) do
    fn
      %{"operation" => "describe"} -> {:ok, envelope(described)}
      %{"operation" => "models"} -> {:ok, envelope(%{"models" => models})}
    end
  end

  test "the listing's window wins, then the table, then the default", %{ctx: ctx} do
    described = %{
      "provider_tools" => ["web_search"],
      "media_types" => ["image/png"],
      "streaming" => false,
      "defaults" => %{"max_tokens" => 8192}
    }

    listed =
      runner(described, [
        %{"id" => "claude-x", "context_window" => 500_000, "max_output_tokens" => 32_000}
      ])

    assert %{
             context_window: 500_000,
             max_output_tokens: 32_000,
             source: :models,
             provider_tools: ["web_search"],
             default_max_tokens: 8192
           } =
             Models.capabilities(ctx, "catalyst:local.claude:1.2.0", "claude-x", "sha256:a",
               run: listed
             )

    unlisted = runner(described, [%{"id" => "claude-x"}])

    assert %{context_window: 200_000, source: :table} =
             Models.capabilities(ctx, "catalyst:local.claude:1.2.0", "claude-x", "sha256:b",
               run: unlisted
             )

    assert %{context_window: 128_000, source: :default} =
             Models.capabilities(ctx, "catalyst:local.mystery:1.0.0", "m", "sha256:c",
               run: unlisted
             )

    failing = fn _ -> {:error, :boom} end

    assert %{context_window: 1_000_000, source: :table, streaming: false} =
             Models.capabilities(ctx, "catalyst:local.gemini:1.2.0", "g", "sha256:d",
               run: failing
             )
  end

  test "a reading is cached under its key and not re-run", %{ctx: ctx} do
    counter = :counters.new(1, [])

    run = fn op ->
      :counters.add(counter, 1, 1)
      runner(%{}, [%{"id" => "m", "context_window" => 1000}]).(op)
    end

    assert %{context_window: 1000} =
             Models.capabilities(ctx, "catalyst:local.claude:1.2.0", "m", "sha256:k", run: run)

    assert %{context_window: 1000} =
             Models.capabilities(ctx, "catalyst:local.claude:1.2.0", "m", "sha256:k", run: run)

    assert :counters.get(counter, 1) == 2

    # Another key reads again.
    assert %{context_window: 1000} =
             Models.capabilities(ctx, "catalyst:local.claude:1.2.0", "m", "sha256:other",
               run: run
             )

    assert :counters.get(counter, 1) == 4
  end

  test "the table is by exact catalyst name" do
    assert Cyfr.Models.Windows.by_catalyst("catalyst:local.grok:1.2.0") == 131_072
    assert Cyfr.Models.Windows.by_catalyst("catalyst:moonmoon69.claude:1.0.0") == 200_000
    assert Cyfr.Models.Windows.by_catalyst("catalyst:local.claude-fast:1.0.0") == nil
    assert Cyfr.Models.Windows.default() == 128_000
  end
end
