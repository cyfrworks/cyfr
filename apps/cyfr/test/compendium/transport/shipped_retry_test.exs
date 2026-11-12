# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Transport.ShippedRetryTest do
  @moduledoc """
  The registry transport's retry at the values a release compiles.

  The suite compiles a 5 ms backoff base (`config/test.exs`). A release's
  configuration sets no base, so `Compendium.Transport.Retry` compiles the
  default its `Application.compile_env/3` names; the proof is in two
  halves: that default, read from the code and absent from the release's
  configuration, is the base a release backs off from, and the transport
  obeys whatever base it was compiled with
  (`Compendium.Registry.TransportTest`, "a 5xx does replay a GET, after each
  attempt's backoff", at the suite's base).

  With it, the longest a retried request can take is computed from the
  code's own bounds and held to the window of the tool call that makes it
  (`Sanctum.Dispatch`, the door `/mcp`, the command line and an assistant's
  tool step take).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../../..", __DIR__)

  # Bounds the dependencies own, which no CYFR option changes on this path
  # (`Prima.Network.pin/3` passes no `:timeout` in `connect_options`, and
  # `Sanctum.Egress` no `:pool_timeout`): Mint's connect (TCP and the TLS
  # handshake together) and Finch's pool checkout.
  @connect_ms 30_000
  @pool_checkout_ms 5_000

  defp quoted(path), do: @root |> Path.join(path) |> File.read!() |> Code.string_to_quoted!()

  # A module attribute's expression as the source sets it.
  defp attribute_ast(path, name) do
    {_ast, found} =
      Macro.prewalk(quoted(path), nil, fn
        {:@, _, [{^name, _, [value]}]} = node, nil -> {node, value}
        node, acc -> {node, acc}
      end)

    refute is_nil(found), "#{path} sets no @#{name}"
    found
  end

  # Its value, evaluated: a literal, or a call such as `:timer.minutes(5)`.
  defp attribute(path, name) do
    {value, _binding} = Code.eval_quoted(attribute_ast(path, name))
    value
  end

  test "a release backs off from 500 ms, and a retried request fits its tool call's window" do
    release = Config.Reader.read!(Path.join(@root, "config/config.exs"), env: :prod)
    refute Keyword.has_key?(Keyword.get(release, :cyfr, []), :transport_retry_base_ms)

    retry = "apps/cyfr/lib/compendium/transport/retry.ex"
    transport = "apps/cyfr/lib/compendium/registry/transport.ex"
    dispatch = "apps/sanctum/lib/sanctum/dispatch.ex"

    # The base `backoff/1` doubles is the setting, defaulting to 500 ms.
    assert {{:., _, [{:__aliases__, _, [:Application]}, :compile_env]}, _,
            [:cyfr, :transport_retry_base_ms, base_ms]} = attribute_ast(retry, :base_delay_ms)

    assert base_ms == 500

    attempts = attribute(transport, :max_retries)
    receive_ms = attribute(transport, :receive_timeout)
    retry_after_ms = attribute(retry, :max_retry_after_ms)

    # Each wait before a further attempt: the backoff, doubling from the
    # base, or a 429's Retry-After at its clamp when that is longer.
    backoffs = for attempt <- 0..(attempts - 2), do: base_ms * Integer.pow(2, attempt)
    assert backoffs == [500, 1_000]

    longest_ms =
      attempts * (@pool_checkout_ms + @connect_ms + receive_ms) +
        Enum.sum(for wait <- backoffs, do: max(wait, retry_after_ms))

    window_ms = attribute(dispatch, :tool_timeout_ms) - attribute(dispatch, :give_back_margin_ms)

    assert longest_ms == 255_000
    assert window_ms == 299_000
    assert longest_ms < window_ms
  end
end
