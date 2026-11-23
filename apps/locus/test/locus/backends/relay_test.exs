# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.RelayTest do
  @moduledoc """
  A session's buffer as data: stdout split into numbered lines whatever
  the chunks, a trailing carriage return dropped and bytes that are not
  UTF-8 replaced; a line past its bound refused; a partial line flushed as
  a line of its own; a terminal's output buffered as chunks of its bytes
  as they are, cut at the chunk bound; a run's lines masked as they are
  buffered; lines let go only once a take names an `after` at or
  above them, so a take repeated answers the same lines; the buffer's
  bound, and a drop to a holding, dropping the oldest lines and a take
  counting them; a take's byte budget, never passed, and the cost of what
  it would answer, which is what an answer encodes; the stderr tail masked
  and cut.
  """
  use ExUnit.Case, async: true

  alias Locus.Backends.Relay

  defp texts(lines), do: Enum.map(lines, & &1.text)

  test "stdout becomes numbered lines, whatever its chunks" do
    {:ok, relay} = Relay.stdout(Relay.new(), "one\ntw")
    refute Relay.past?(relay, 1)
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
    assert {[%{seq: 1, text: "Paste the code: "}], 0, _relay} = Relay.take(relay, 0, 1_000)
    assert Relay.flush(relay) == relay
  end

  test "a terminal's output is chunks of its bytes as they are, none past the chunk bound" do
    max = Prima.LocusBackends.max_chunk_bytes()
    raw = <<0xFF, 0xFE, "\e[1mbold\e[0m\r\n", 0x03>>
    long = :binary.copy("x", max + 1)

    relay =
      Relay.new(mode: :terminal)
      |> Relay.output(raw)
      |> Relay.output("")
      |> Relay.output(long)

    assert {chunks, 0, _relay} = Relay.take(relay, 0, 1_000_000)

    assert chunks == [
             %{seq: 1, bytes: raw},
             %{seq: 2, bytes: binary_part(long, 0, max)},
             %{seq: 3, bytes: "x"}
           ]
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

  test "a take answers what fits its budget and never more; the cost asked for counts one line at least" do
    {:ok, relay} = Relay.stdout(Relay.new(), "aaaa\nbbbb\n")
    one = Relay.cost(relay, 0, 1)
    assert one == byte_size(Jason.encode!("aaaa")) + 32
    assert {[], 0, relay} = Relay.take(relay, 0, one - 1)
    {first, 0, relay} = Relay.take(relay, 0, one)
    assert texts(first) == ["aaaa"]
    {both, 0, _relay} = Relay.take(relay, 0, 1_000)
    assert texts(both) == ["aaaa", "bbbb"]
  end

  test "the cost of what a take answers is what an answer encodes it as, past its after" do
    written = [~s(quote " and \\ back), <<1, 2, 0x1F, ?\t, ?\r, ?\b, ?\f>>, "é€😀", "plain", ""]
    {:ok, relay} = Relay.stdout(Relay.new(), Enum.map_join(written, &(&1 <> "\n")))
    encoded = Enum.map(written, &(byte_size(Jason.encode!(&1)) + 32))

    assert Relay.cost(relay, 0, 1_000_000) == Enum.sum(encoded)
    assert Relay.cost(relay, 2, 1_000_000) == encoded |> Enum.drop(2) |> Enum.sum()
    assert Relay.cost(relay, length(written), 1_000_000) == 0
    assert {lines, 0, _relay} = Relay.take(relay, 0, Relay.cost(relay, 0, 1_000_000))
    assert texts(lines) == written

    chunk = <<0xFF, 0, ?a>> <> :binary.copy("b", 100)
    terminal = Relay.output(Relay.new(mode: :terminal), chunk)
    assert Relay.cost(terminal, 0, 1_000_000) == byte_size(Base.encode64(chunk)) + 32
  end

  test "a drop to a holding lets the oldest lines go until it holds at most that, counted as the bound counts them" do
    {:ok, relay} = Relay.stdout(Relay.new(line_charge_bytes: 1), "aa\nbb\ncc\n")
    assert relay.bytes == 9

    relay = Relay.drop_to(relay, 7)
    assert {relay.bytes, Relay.dropped(relay)} == {6, 1}
    assert Relay.drop_to(relay, 6) == relay
    {lines, dropped, _relay} = Relay.take(relay, 0, 1_000)
    assert {texts(lines), dropped} == {["bb", "cc"], 1}

    emptied = Relay.drop_to(relay, 0)
    assert {emptied.bytes, Relay.dropped(emptied)} == {0, 3}
    assert {[], 3, _relay} = Relay.take(emptied, 0, 1_000)
    assert {[], 1, _relay} = Relay.take(emptied, 2, 1_000)
  end

  test "a run's lines are masked as they are buffered, and charged as masked" do
    relay = Relay.new(secrets: ["secret-123456"], line_charge_bytes: 0)
    {:ok, relay} = Relay.stdout(relay, "token secret-123456\n")
    assert {[%{text: "token [REDACTED]"}], 0, relay} = Relay.take(relay, 0, 1_000)
    assert relay.bytes == byte_size("token [REDACTED]")
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
