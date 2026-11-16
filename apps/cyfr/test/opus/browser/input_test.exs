# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Browser.InputTest do
  @moduledoc """
  The person's input, the host's side, against the vectors the driver
  reads too (`tests/fixtures/browser_frames.json`'s `input`): every event
  they accept is read, alone and as many as one message holds; every
  event they refuse is refused and takes its message with it; a message
  of none, or of one past the bound, is refused.
  """
  use ExUnit.Case, async: true

  alias Opus.Browser.Input

  @vectors Path.expand("../../../../../tests/fixtures/browser_frames.json", __DIR__)
  @external_resource @vectors

  setup_all do
    vectors = @vectors |> File.read!() |> Jason.decode!()
    {:ok, input: vectors["input"], in_flight: vectors["input_in_flight"]}
  end

  test "the bounds are the vectors'", %{input: input, in_flight: in_flight} do
    assert Input.max_events() == input["max_events"]
    assert Input.in_flight() == in_flight
  end

  test "every event the vectors accept is read, and none beside a refused one",
       %{input: input} do
    assert input["accept"] != []
    [%{"event" => refused} | _] = input["refuse"]

    for %{"name" => name, "event" => event} <- input["accept"] do
      assert Input.events([event]) == {:ok, [event]}, name
      assert Input.events([event, refused]) == :error, name
    end
  end

  test "every event the vectors refuse is refused", %{input: input} do
    assert input["refuse"] != []

    for %{"name" => name, "event" => event} <- input["refuse"],
        do: assert(Input.events([event]) == :error, name)
  end

  test "a message holds at most the bound's events and at least one", %{input: input} do
    events =
      input["accept"]
      |> Stream.cycle()
      |> Stream.map(& &1["event"])
      |> Enum.take(Input.max_events() + 1)

    assert {:ok, most} = Input.events(Enum.take(events, Input.max_events()))
    assert length(most) == Input.max_events()
    assert Input.events(events) == :error
    assert Input.events([]) == :error
    assert Input.events(%{}) == :error
  end
end
