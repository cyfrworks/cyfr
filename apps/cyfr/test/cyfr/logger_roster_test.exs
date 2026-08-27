# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.LoggerRosterTest do
  @moduledoc """
  The metadata roster existed in three places: `config/config.exs`,
  `config/runtime.exs`'s JSON branch, and a hardcoded fallback inside
  `Cyfr.JsonFormatter` — which carried three keys the config never
  requested and therefore never emitted.

  Config files run before application code is loaded, so the roster cannot
  literally be one expression. It can be one *checked* expression: the keys
  `Cyfr.LoggerContext` sets must be the keys the formatter is configured to
  print, or the metadata is written and silently dropped.
  """

  use ExUnit.Case, async: true

  defp root, do: Path.expand("../../../..", __DIR__)

  test "the configured roster carries every key LoggerContext sets" do
    configured = Application.get_env(:logger, :default_formatter, [])[:metadata]

    assert is_list(configured),
           "config/config.exs must set :logger, :default_formatter, metadata: [...]"

    missing = Cyfr.LoggerContext.keys() -- configured

    assert missing == [],
           """
           `Cyfr.LoggerContext` sets metadata the log roster does not print:

             #{inspect(missing)}

           Add them to `metadata:` in config/config.exs, or stop setting them.
           """
  end

  test "runtime.exs overrides only the format, never the roster" do
    runtime = File.read!(Path.join(root(), "config/runtime.exs"))

    lines = String.split(runtime, "\n")

    # The call and any continuation lines its keyword list spills onto.
    json_branch =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _i} ->
        String.contains?(line, "config :logger, :default_formatter")
      end)
      |> Enum.flat_map(fn {_line, i} -> Enum.slice(lines, i, 4) end)

    assert json_branch != [], "the JSON log format branch went missing"

    refute Enum.any?(json_branch, &String.contains?(&1, "metadata")),
           """
           config/runtime.exs re-declares the metadata roster. `Config`
           deep-merges keyword values, so config.exs's roster already carries
           through; a second copy only supplies something to go stale.
           """
  end
end
