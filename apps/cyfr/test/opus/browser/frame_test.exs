# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Browser.FrameTest do
  @moduledoc """
  The host's side of the browser driver's framing against the vectors the
  driver reads too (`tests/fixtures/browser_frames.json`): every body
  encodes to the exact frame, and a stream fed piece by piece gives the
  bodies and the bytes still held, a cut, corrupt or oversized frame
  never taken as whole; and the bounds, a put's among them, are the
  vectors'.
  """
  use ExUnit.Case, async: true

  alias Opus.Browser.Frame

  @vectors Path.expand("../../../../../tests/fixtures/browser_frames.json", __DIR__)
  @external_resource @vectors

  setup_all do
    {:ok, vectors: @vectors |> File.read!() |> Jason.decode!()}
  end

  test "the bounds are the vectors'", %{vectors: vectors} do
    assert Frame.max_to_host() == vectors["max_to_host"]
    assert Frame.max_to_driver() == vectors["max_to_driver"]
    assert Frame.max_response() == vectors["max_response"]
    assert vectors["start"] == <<0x1E, "B1">>
  end

  test "a put's bounds are the vectors', and a part of the most bytes is a frame the driver takes",
       %{vectors: vectors} do
    assert vectors["put"] == %{
             "max_bytes" => Frame.put_max_bytes(),
             "max_files" => Frame.put_max_files(),
             "part_bytes" => Frame.put_part_bytes()
           }

    base64 = 4 * div(Frame.put_part_bytes() + 2, 3)
    envelope = byte_size(~s({"t":"part","id":#{2 ** 63},"seq":#{2 ** 63},"part":""}))
    assert base64 + envelope <= Frame.max_to_driver()
  end

  test "every body encodes to its exact frame", %{vectors: vectors} do
    assert vectors["encode"] != []

    for %{"name" => name, "body" => body, "frame" => frame} <- vectors["encode"],
        do: assert(Frame.encode(body) == frame, name)
  end

  test "a stream fed piece by piece gives its bodies and holds the rest", %{vectors: vectors} do
    assert vectors["decode"] != []

    for %{"name" => name, "max" => max, "stream" => pieces} = vector <- vectors["decode"] do
      {bodies, rest} =
        Enum.reduce(pieces, {[], ""}, fn piece, {bodies, held} ->
          {more, held} = Frame.decode(held <> piece, max)
          {bodies ++ more, held}
        end)

      assert {bodies, rest} == {vector["frames"], vector["rest"]}, name
    end
  end

  test "every message names the fields its vector lists", %{vectors: vectors} do
    for {type, %{"fields" => fields, "example" => example}} <- vectors["messages"] do
      assert example["t"] == type
      assert Enum.sort(Map.keys(example)) == Enum.sort(fields), type
      assert {[body], ""} = Frame.decode(Frame.message(example))
      assert Jason.decode!(body) == example
    end
  end
end
