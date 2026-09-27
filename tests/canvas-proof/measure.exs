# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The vault page's operations measured inside a running server, evaluated
# by `bin/cyfr rpc` (tests/canvas-proof/run.sh): `vault.list` and
# `vault.status`, each called CALLS times at CONCURRENCY at once, as the
# console calls a tool for the session's person (`PrismWeb.Ops.call_tool/3`,
# through the gate). Evaluates to a function of [token, calls, concurrency]
# that answers one line, `MEASURE=` and a JSON object: per operation the
# count, the refusals and p50, p95 and p99 in milliseconds. Recorded, not
# gated.

fn [token, calls, concurrency] ->
  {:ok, ctx} = Sanctum.Caller.establish({:session, token})
  calls = String.to_integer(calls)
  concurrency = String.to_integer(concurrency)

  percentile = fn sorted, p ->
    rank = max(0, min(length(sorted) - 1, ceil(p / 100 * length(sorted)) - 1))
    sorted |> Enum.at(rank) |> Kernel./(1000) |> Float.round(2)
  end

  measure = fn tool ->
    results =
      1..calls
      |> Task.async_stream(
        fn _ ->
          {micros, answer} = :timer.tc(fn -> PrismWeb.Ops.call_tool(ctx, tool, %{}) end)
          {micros, match?({:ok, _}, answer)}
        end,
        max_concurrency: concurrency,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    sorted = results |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    %{
      n: length(results),
      refused: Enum.count(results, &(not elem(&1, 1))),
      p50: percentile.(sorted, 50),
      p95: percentile.(sorted, 95),
      p99: percentile.(sorted, 99)
    }
  end

  "MEASURE=" <>
    Jason.encode!(%{
      adapter: Application.get_env(:arca, :database_adapter) |> inspect(),
      concurrency: concurrency,
      calls: calls,
      "vault.list": measure.("vault/list"),
      "vault.status": measure.("vault/status")
    })
end
