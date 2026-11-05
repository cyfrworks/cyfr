# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.RelayTest do
  @moduledoc """
  A session's buffer as data: stdout split into numbered lines whatever
  the chunks, a trailing carriage return dropped and bytes that are not
  UTF-8 replaced; a line past its bound refused; a partial line flushed as
  a line of its own; lines let go only once a take names an `after` at or
  above them, so a take repeated answers the same lines; the buffer's
  bound dropping the oldest lines and a take counting them; a take's byte
  budget; the stderr tail masked and cut.
  """
  use ExUnit.Case, async: true

  alias Locus.Backends.Relay

  defp texts(lines), do: Enum.map(lines, & &1.text)

  test "stdout becomes numbered lines, whatever its chunks" do
    {:ok, relay} = Relay.stdout(Relay.new(), "one\ntw")
    assert Relay.partial?(relay)
    {:ok, relay} = Relay.stdout(relay, "o\r\nthree\n")

    {lines, 0, _relay} = Relay.take(relay, 0, 1_000_000)
    assert lines == [%{seq: 1, text: "one"}, %{seq: 2, text: "two"}, %{seq: 3, text: "three"}]
  end

  test "a line that is not UTF-8 is text all the same" do
    {:ok, relay} = Relay.stdout(Relay.new(), <<"a", 0xFF, "b\n">>)
    {[%{text: text}], 0, _relay} = Relay.take(relay, 0, 1_000_000)
    assert String.valid?(text)
    assert text =~ "a" and text =~ "b"
  end

  test "a line past its bound, whole or still partial, is refused" do
    relay = Relay.new(max_line_bytes: 8)
    assert {:error, :line_too_long} = Relay.stdout(relay, "123456789\n")
    assert {:error, :line_too_long} = Relay.stdout(relay, "123456789")
    assert {:ok, _relay} = Relay.stdout(relay, "12345678\n")
  end

  test "a flush makes the partial line a line of its own" do
    {:ok, relay} = Relay.stdout(Relay.new(), "Paste the code: ")
    refute Relay.past?(relay, 0)
    relay = Relay.flush(relay)
    refute Relay.partial?(relay)
    assert {[%{seq: 1, text: "Paste the code: "}], 0, _relay} = Relay.take(relay, 0, 1_000)
    assert Relay.flush(relay) == relay
  end

  test "a take lets go of what its after names, and answers the same lines when repeated" do
    {:ok, relay} = Relay.stdout(Relay.new(), "a\nb\nc\n")

    {first, 0, relay} = Relay.take(relay, 0, 1_000)
    {again, 0, relay} = Relay.take(relay, 0, 1_000)
    assert first == again

    {rest, 0, relay} = Relay.take(relay, 2, 1_000)
    assert texts(rest) == ["c"]
    assert relay.bytes == 1 + Prima.LocusBackends.line_charge_bytes()
    refute Relay.past?(relay, 3)
  end

  test "the buffer's bound drops the oldest lines, and a take counts them" do
    relay = Relay.new(max_buffer_bytes: 6, line_charge_bytes: 1)
    {:ok, relay} = Relay.stdout(relay, "aa\nbb\ncc\n")

    assert Relay.dropped(relay) == 1
    {lines, dropped, _relay} = Relay.take(relay, 0, 1_000)
    assert texts(lines) == ["bb", "cc"]
    assert dropped == 1
  end

  test "empty lines are bounded and counted: by their framing and by their number" do
    {:ok, by_count} = Relay.stdout(Relay.new(max_buffer_lines: 3), String.duplicate("\n", 5))
    assert Relay.dropped(by_count) == 2
    {lines, dropped, _relay} = Relay.take(by_count, 0, 1_000)
    assert texts(lines) == ["", "", ""]
    assert dropped == 2

    relay = Relay.new(max_buffer_bytes: 32 * 100)
    {:ok, by_bytes} = Relay.stdout(relay, String.duplicate("\n", 10_000))
    assert Relay.dropped(by_bytes) == 10_000 - 100
    assert by_bytes.bytes <= 32 * 100
  end

  test "a take answers what fits its budget, and one line at least" do
    {:ok, relay} = Relay.stdout(Relay.new(), "aaaa\nbbbb\n")
    {one, 0, relay} = Relay.take(relay, 0, 1)
    assert texts(one) == ["aaaa"]
    {both, 0, _relay} = Relay.take(relay, 0, 1_000)
    assert texts(both) == ["aaaa", "bbbb"]
  end

  test "every byte of stderr is counted, beyond the tail kept" do
    relay = Relay.new(stderr_tail_bytes: 4, stderr_tail_slack_bytes: 0)
    relay = relay |> Relay.stderr("abcdef") |> Relay.stderr("gh")
    assert Relay.stderr_bytes(relay) == 8
    assert byte_size(relay.stderr) == 4
  end

  test "the stderr tail is masked and cut to its bound" do
    relay = Relay.new(stderr_tail_bytes: 16, stderr_tail_slack_bytes: 8)
    relay = Relay.stderr(relay, "noise noise token secret-123456 ok\n")
    tail = Relay.stderr_tail(relay, ["secret-123456"])
    assert byte_size(tail) <= 16
    refute tail =~ "secret-123456"
  end
end
