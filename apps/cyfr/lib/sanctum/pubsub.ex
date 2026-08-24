# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PubSub do
  @moduledoc """
  Tenant-aware PubSub topic helper.

  Prefixes every topic with `"tenant:<athanor_id>:"` so broadcasts are
  isolated per athanor. This module owns the prefix and the refusal; it does
  not own the vocabulary — every topic name, and the messages each carries,
  is named in `Prism.Topics`, including the handful that are deliberately
  global.
  """

  alias Sanctum.Context

  @doc """
  Build a tenant-scoped topic string.

  Takes the athanor as a `Sanctum.Context` or as a bare id, because some
  producers only ever hold the id — a telemetry handler reading
  `metadata[:athanor_id]`, a buffer keyed by athanor. Both arrive at the same
  prefix and the same refusal; synthesising a `Context` just to satisfy the
  signature would skip `Context.build/1`'s validation without buying anything.
  A `nil` or empty athanor indicates a bug and raises.

  ## Examples

      iex> ctx = %Sanctum.Context{athanor_id: "ath_1"}
      iex> Sanctum.PubSub.topic("execution:events", ctx)
      "tenant:ath_1:execution:events"

      iex> Sanctum.PubSub.topic("execution:events", "ath_1")
      "tenant:ath_1:execution:events"
  """
  @spec topic(String.t(), Context.t() | String.t() | nil) :: String.t()
  def topic(base, nil) do
    raise ArgumentError,
          "PubSub.topic/2 requires a non-nil context with athanor_id, " <>
            "got nil for topic #{inspect(base)}"
  end

  def topic(base, %Context{athanor_id: athanor_id}) when athanor_id in [nil, ""] do
    raise ArgumentError,
          "PubSub.topic/2 requires a Context with non-empty athanor_id, " <>
            "got #{inspect(athanor_id)} for topic #{inspect(base)}"
  end

  def topic(base, %Context{athanor_id: athanor_id}), do: topic(base, athanor_id)

  def topic(base, athanor_id) when is_binary(athanor_id) and athanor_id != "" do
    "tenant:#{athanor_id}:#{base}"
  end

  def topic(base, other) do
    raise ArgumentError,
          "PubSub.topic/2 requires a Context or a non-empty athanor_id, " <>
            "got #{inspect(other)} for topic #{inspect(base)}"
  end
end
