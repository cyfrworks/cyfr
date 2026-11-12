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

  How long a retried request can take in all is not asserted here: the
  transport's receive timeout bounds the silence between chunks of an
  answer, not the answer, so no sum of these values is a ceiling.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../../..", __DIR__)

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

  # Its value, evaluated.
  defp attribute(path, name) do
    {value, _binding} = Code.eval_quoted(attribute_ast(path, name))
    value
  end

  test "a release backs off from 500 ms, then 1 s, over three attempts" do
    release = Config.Reader.read!(Path.join(@root, "config/config.exs"), env: :prod)
    refute Keyword.has_key?(Keyword.get(release, :cyfr, []), :transport_retry_base_ms)

    retry = "apps/cyfr/lib/compendium/transport/retry.ex"
    transport = "apps/cyfr/lib/compendium/registry/transport.ex"

    # The base `backoff/1` doubles is the setting, defaulting to 500 ms.
    assert {{:., _, [{:__aliases__, _, [:Application]}, :compile_env]}, _,
            [:cyfr, :transport_retry_base_ms, base_ms]} = attribute_ast(retry, :base_delay_ms)

    assert base_ms == 500

    attempts = attribute(transport, :max_retries)
    assert attempts == 3

    # Each wait before a further attempt: the backoff, doubling from the
    # base.
    backoffs = for attempt <- 0..(attempts - 2), do: base_ms * Integer.pow(2, attempt)
    assert backoffs == [500, 1_000]
  end
end
