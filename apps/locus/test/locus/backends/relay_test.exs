# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.RelayTest do
  @moduledoc """
  A backend's stdio as data, from literal bytes: an attach connection's
  frames decoded, a frame the codec refuses or on a stream the relay never
  sends a fault; stdout split into JSON-RPC lines however it arrives, a
  line or an unfinished one past the frame bound refused; the stderr tail
  and its slack, masked before the cut; the backend's own requests never
  answering a call, whatever their id; an answer naming its call by the
  minted id or the string spelling it; everything else dropped and
  counted.
  """

  use ExUnit.Case, async: true

  alias Locus.Backends.Relay

  defp frame(stream, payload), do: <<stream, byte_size(payload)::32, payload::binary>>

  defp line(message), do: Jason.encode!(message) <> "\n"

  # A relay with one call pending under id 1, tagged `:first`.
  defp pending(opts \\ []) do
    {line, 1, relay} = Relay.request(Relay.new(opts), "tools/call", %{name: "echo"}, :first)

    assert Jason.decode!(IO.iodata_to_binary(line)) == %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "method" => "tools/call",
             "params" => %{"name" => "echo"}
           }

    relay
  end

  describe "frames" do
    test "stdout and stderr frames are decoded, however the bytes are cut" do
      bytes =
        frame(1, line(%{jsonrpc: "2.0", id: 1, result: %{ok: true}})) <>
          frame(2, "warming up\n") <> frame(1, "") <> frame(2, "")

      for cut <- [1, 3, 5, 7, byte_size(bytes) - 1] do
        <<head::binary-size(^cut), tail::binary>> = bytes
        assert {:ok, first, relay} = Relay.frames(pending(), head)
        assert {:ok, rest, relay} = Relay.frames(relay, tail)
        assert first ++ rest == [{:answer, :first, {:result, %{"ok" => true}}}]
        assert Relay.stderr_tail(relay, []) == "warming up\n"
      end
    end

    test "a frame the codec refuses, or on a stream a relay never sends, is the relay's fault" do
      for bytes <- [
            frame(0, "{}\n"),
            frame(3, String.duplicate("ab", 32)),
            frame(4, "{}\n"),
            <<9, 0::32>>,
            <<1, Prima.KeeperProtocol.max_frame_bytes() + 1::32>>
          ] do
        assert {:error, :relay_protocol} = Relay.frames(Relay.new(), bytes)
      end
    end

    test "a stdout line past the frame bound inside frames is refused" do
      relay = Relay.new(max_frame_bytes: 10)
      assert {:error, :frame_too_large} = Relay.frames(relay, frame(1, "01234567890\n"))
    end
  end

  describe "stdout" do
    test "lines are split on newlines across chunks; blank lines are nothing" do
      relay = pending()
      [whole] = [line(%{jsonrpc: "2.0", id: 1, result: "done"})]
      <<a::binary-size(10), b::binary>> = whole

      assert {:ok, [], relay} = Relay.stdout(relay, "\n  \n" <> a)
      assert {:ok, [{:answer, :first, {:result, "done"}}], relay} = Relay.stdout(relay, b)
      assert Relay.pending_count(relay) == 0
      assert Relay.dropped(relay) == 0
    end

    test "a line, or an unfinished one, longer than the frame bound is refused" do
      relay = Relay.new(max_frame_bytes: 16)
      assert {:ok, [], relay} = Relay.stdout(relay, String.duplicate("x", 16))
      assert {:error, :frame_too_large} = Relay.stdout(relay, "x")

      assert {:error, :frame_too_large} =
               Relay.stdout(Relay.new(max_frame_bytes: 16), String.duplicate("y", 17) <> "\n")

      # The bound is the one `Prima.LocusBackends` names.
      assert Relay.new().max_frame_bytes == Prima.LocusBackends.max_frame_bytes()
    end

    test "a message carrying a method is the backend's own, and never answers a call, whatever its id" do
      relay = pending()

      assert {:ok, events, relay} =
               Relay.stdout(
                 relay,
                 line(%{jsonrpc: "2.0", id: 1, method: "sampling/createMessage", result: "x"}) <>
                   line(%{jsonrpc: "2.0", method: "notifications/progress"})
               )

      assert events == [
               {:child, 1, "sampling/createMessage"},
               {:child, nil, "notifications/progress"}
             ]

      assert Relay.pending_count(relay) == 1
    end

    test "an answer names its call by the minted id, a number or the string spelling it" do
      for id <- [1, 1.0, "1", " 1 ", "1.0"] do
        assert {:ok, [{:answer, :first, {:error, %{"code" => -1}}}], relay} =
                 Relay.stdout(
                   pending(),
                   line(%{jsonrpc: "2.0", id: id, error: %{code: -1}})
                 )

        assert Relay.pending_count(relay) == 0
      end

      for id <- ["01x", "one", "", 2, "2", 1.5, true, [1]] do
        assert {:ok, [], relay} =
                 Relay.stdout(pending(), line(%{jsonrpc: "2.0", id: id, result: "x"}))

        assert Relay.pending_count(relay) == 1
        assert Relay.dropped(relay) == 1
      end
    end

    test "anything else is dropped and counted" do
      relay = pending()

      assert {:ok, [], relay} =
               Relay.stdout(
                 relay,
                 "not json\n" <>
                   "[1, 2]\n" <>
                   line(%{jsonrpc: "2.0", id: 1}) <>
                   line(%{jsonrpc: "2.0", id: nil, result: "x"}) <>
                   line(%{jsonrpc: "2.0", result: "x"})
               )

      assert Relay.dropped(relay) == 5
      assert Relay.pending_count(relay) == 1

      # The pending call is still answered.
      assert {:ok, [{:answer, :first, {:result, nil}}], _relay} =
               Relay.stdout(relay, line(%{jsonrpc: "2.0", id: 1, result: nil}))
    end
  end

  describe "calls" do
    test "ids are minted in order, cancelled one at a time or taken all at once, and start over for the next process" do
      relay = pending()
      {_line, 2, relay} = Relay.request(relay, "tools/list", nil, :second)
      {_line, 3, relay} = Relay.request(relay, "tools/list", nil, :third)

      assert {:second, relay} = Relay.cancel(relay, 2)
      assert {nil, relay} = Relay.cancel(relay, 2)
      assert {[:first, :third], relay} = Relay.take_pending(relay)
      assert Relay.pending_count(relay) == 0

      relay = relay |> Relay.stderr("kept") |> Relay.restart()
      assert {_line, 1, _relay} = Relay.request(relay, "initialize", %{}, :init)
      assert Relay.stderr_tail(relay, []) == "kept"
    end

    test "a notification and an answer to the backend's own request are lines of their own" do
      notification = IO.iodata_to_binary(Relay.notification("notifications/initialized"))
      assert String.ends_with?(notification, "}\n")

      assert Jason.decode!(notification) == %{
               "jsonrpc" => "2.0",
               "method" => "notifications/initialized"
             }

      assert Jason.decode!(IO.iodata_to_binary(Relay.reply_error(7, -32_601, "no"))) == %{
               "jsonrpc" => "2.0",
               "id" => 7,
               "error" => %{"code" => -32_601, "message" => "no"}
             }
    end
  end

  describe "stderr" do
    test "the tail and its slack are kept, the secret masked before the cut is taken" do
      relay = Relay.new(stderr_tail_bytes: 16, stderr_tail_slack_bytes: 8)
      relay = Relay.stderr(relay, String.duplicate("a", 30))
      assert byte_size(relay.stderr) == 24

      # A secret the cut would split is masked whole first.
      relay = Relay.stderr(relay, "token=s3cr3t-value!")
      tail = Relay.stderr_tail(relay, ["s3cr3t-value"])
      refute tail =~ "s3cr3t"
      assert tail == String.slice("token=[REDACTED]!", -16, 16)
      assert byte_size(tail) <= 16
    end

    test "the bounds are the ones Prima.LocusBackends names, and the tail is text" do
      relay = Relay.new()
      assert relay.tail_bytes == Prima.LocusBackends.stderr_tail_bytes()
      assert relay.slack_bytes == Prima.LocusBackends.stderr_tail_slack_bytes()

      cut = Relay.new(stderr_tail_bytes: 3, stderr_tail_slack_bytes: 0)
      tail = cut |> Relay.stderr("aé€") |> Relay.stderr_tail([])
      assert String.valid?(tail)
    end
  end
end
