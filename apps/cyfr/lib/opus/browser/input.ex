# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Browser.Input do
  @moduledoc """
  The person's input to a window they watch (C12), the host's side: the
  events `tests/fixtures/browser_frames.json`'s `input` defines, which
  the driver (`apps/locus/keeper/cmd/cyfr-browser`) reads by the same
  vectors. An event is a mouse button or move, a wheel or a key, with
  exactly its kind's fields; its place is a fraction of the image the
  person sees, from its top left, which the driver maps onto the window.
  One message carries at most `max_events/0` of them, and one event
  that does not read refuses them all.
  """

  @max_events 64
  @fields %{
    "mouse" => ~w(k type x y button clicks mods),
    "wheel" => ~w(k x y dx dy mods),
    "key" => ~w(k type key code text vk mods)
  }

  @doc "The most events one message carries."
  @spec max_events() :: pos_integer()
  def max_events, do: @max_events

  @doc """
  The events, each as the driver reads it, or `:error` when any is not
  an event or there are none or more than `max_events/0`.
  """
  @spec events(term()) :: {:ok, [map()]} | :error
  def events(events) when is_list(events) and events != [] do
    if length(events) <= @max_events and Enum.all?(events, &event?/1),
      do: {:ok, events},
      else: :error
  end

  def events(_not_a_list), do: :error

  defp event?(%{"k" => kind} = event) when is_map_key(@fields, kind) do
    fields = @fields[kind]

    map_size(event) == length(fields) and Enum.all?(fields, &Map.has_key?(event, &1)) and
      valid?(kind, event)
  end

  defp event?(_other), do: false

  defp valid?("mouse", event) do
    event["type"] in ~w(down up move) and fraction?(event["x"]) and fraction?(event["y"]) and
      event["button"] in ~w(none left middle right) and whole?(event["clicks"], 0, 3) and
      mods?(event["mods"])
  end

  defp valid?("wheel", event) do
    fraction?(event["x"]) and fraction?(event["y"]) and delta?(event["dx"]) and
      delta?(event["dy"]) and mods?(event["mods"])
  end

  defp valid?("key", event) do
    event["type"] in ~w(down up) and text?(event["key"], 1, 32) and code?(event["code"]) and
      text?(event["text"], 0, 16) and whole?(event["vk"], 0, 255) and mods?(event["mods"])
  end

  defp fraction?(value), do: is_number(value) and value >= 0 and value <= 1
  defp delta?(value), do: is_number(value) and value >= -10_000 and value <= 10_000
  defp whole?(value, low, high), do: is_integer(value) and value >= low and value <= high
  defp mods?(value), do: whole?(value, 0, 15)

  defp text?(value, low, high),
    do: is_binary(value) and byte_size(value) in low..high//1 and String.valid?(value)

  defp code?(value), do: is_binary(value) and value =~ ~r/\A[A-Za-z0-9]{0,32}\z/
end
