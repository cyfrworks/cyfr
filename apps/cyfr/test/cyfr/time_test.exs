# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.TimeTest do
  @moduledoc """
  `Cyfr.Time.iso8601/1` is the one timestamp renderer for the wire, so what
  it does to a string it did not produce matters.

  Its string arm exists to repair a datetime that arrived without an
  offset. It used to append "Z" to anything that did not already end in one
  — which turned a bare date into the invalid "2026-01-01Z" and any
  non-timestamp string into nonsense with the authority of a formatter.
  """
  use ExUnit.Case, async: true

  alias Cyfr.Time

  test "a DateTime and a NaiveDateTime both render as UTC" do
    assert Time.iso8601(~U[2026-08-31 12:34:56Z]) == "2026-08-31T12:34:56Z"
    assert Time.iso8601(~N[2026-08-31 12:34:56]) == "2026-08-31T12:34:56Z"
  end

  test "nil stays nil" do
    assert Time.iso8601(nil) == nil
  end

  test "a string that already carries an offset passes through untouched" do
    for value <- [
          "2026-08-31T12:34:56Z",
          "2026-08-31T12:34:56+02:00",
          "2026-08-31T12:34:56.123456Z"
        ] do
      assert Time.iso8601(value) == value
    end
  end

  test "an offset-less datetime gains its Z — that is what the arm is for" do
    assert Time.iso8601("2026-08-31T12:34:56") == "2026-08-31T12:34:56Z"
    assert Time.iso8601("2026-08-31 12:34:56") == "2026-08-31 12:34:56Z"
    assert Time.iso8601("2026-08-31T12:34:56.123") == "2026-08-31T12:34:56.123Z"
  end

  test "anything that is not a datetime is returned unchanged, not decorated" do
    for value <- ["2026-08-31", "", "never", "unknown", "not a timestamp"] do
      assert Time.iso8601(value) == value,
             "iso8601/1 rewrote #{inspect(value)}, which is not a timestamp to repair"
    end
  end
end
