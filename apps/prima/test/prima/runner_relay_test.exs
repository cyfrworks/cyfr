# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.RunnerRelayTest do
  @moduledoc """
  The runner relay codec reproduces the shared vectors
  (`tests/fixtures/runner_relay.json`, which Opus's runner and worker
  service read too): the exchange, played between a runner's channel and a
  service's, encodes every frame to exactly its bytes and decodes each to
  the frame sent, one example of every kind among them and a fetch whose
  initial credit is spent and granted again; every refusal closes the
  channel with its reason. The bounds are the fixture's and
  `Prima.HostAPI`'s. The service's channel never encodes a chunk past the
  credit outstanding, and the encoder raises on what the decoder would
  refuse as malformed.
  """

  use ExUnit.Case, async: true

  alias Prima.{HostAPI, PinnedTarget, RunnerRelay, WorkerAuth, WorkerWire}

  @vectors Path.expand("../../../../tests/fixtures/runner_relay.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  @attempt @vectors["attempt"]

  defp json(%{"json" => json}), do: json

  defp json(%{"json_fill" => %{"prefix" => p, "repeat" => r, "times" => n, "suffix" => s}}),
    do: p <> String.duplicate(r, n) <> s

  defp encoded(%{"encoded_hex" => hex}), do: Base.decode16!(hex, case: :lower)

  defp encoded(vector) do
    json = json(vector)
    <<byte_size(json)::32, json::binary>>
  end

  # The frame a vector's JSON spells, as `encode/2` takes it.
  defp frame(json) do
    object = Jason.decode!(json)

    object
    |> Map.drop(["v", "seq"])
    |> Map.new(fn
      {"kind", kind} -> {:kind, String.to_existing_atom(kind)}
      {"op", op} -> {:op, String.to_existing_atom(op)}
      {"body", body} -> {:body, Base.decode64!(body)}
      {"headers", nil} -> {:headers, nil}
      {"headers", headers} -> {:headers, Enum.map(headers, &List.to_tuple/1)}
      {name, value} -> {String.to_existing_atom(name), value}
    end)
  end

  defp side("runner"), do: :runner
  defp side("service"), do: :service

  defp channels,
    do: %{
      runner: RunnerRelay.new(:runner, @attempt),
      service: RunnerRelay.new(:service, @attempt)
    }

  # The exchange's first `count` frames played between the two channels.
  defp play(count) do
    @vectors["exchange"]
    |> Enum.take(count)
    |> Enum.reduce(channels(), fn vector, channels ->
      from = side(vector["from"])
      to = if from == :runner, do: :service, else: :runner
      bytes = encoded(vector)
      sent = frame(json(vector))

      {:ok, iodata, sender} = RunnerRelay.encode(channels[from], sent)
      assert IO.iodata_to_binary(iodata) == bytes, vector["why"]

      if digest = vector["encoded_sha256"],
        do: assert(Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == digest)

      assert {:ok, [received], "", receiver} = RunnerRelay.decode(channels[to], bytes)
      assert received == Map.put(sent, :seq, Jason.decode!(json(vector))["seq"]), vector["why"]
      %{channels | from => sender, to => receiver}
    end)
  end

  test "the bounds are the fixture's and the host API's" do
    assert RunnerRelay.version() == @vectors["version"]
    assert RunnerRelay.max_body_bytes() == @vectors["max_body_bytes"]
    assert RunnerRelay.max_body_bytes() == HostAPI.max_answer_bytes()
    assert RunnerRelay.max_frame_bytes() == @vectors["max_frame_bytes"]
    assert RunnerRelay.initial_credit() == @vectors["initial_credit"]
    # The largest body in base64 fits a frame with room for its envelope.
    assert div(RunnerRelay.max_body_bytes() + 2, 3) * 4 + 65_536 < RunnerRelay.max_frame_bytes()
  end

  test "the exchange holds one frame of every kind, each sent by its side" do
    kinds =
      Enum.map(@vectors["exchange"], fn vector ->
        kind =
          vector |> json() |> Jason.decode!() |> Map.fetch!("kind") |> String.to_existing_atom()

        assert RunnerRelay.sender(kind) in [side(vector["from"]), :either]
        kind
      end)

    assert Enum.sort(Enum.uniq(kinds)) == Enum.sort(RunnerRelay.kinds())
  end

  test "the exchange's host call is a real one: its header verifies and its bodies open" do
    auth =
      Path.expand("../../../../tests/fixtures/worker_auth.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    [call, answer, fetch | _rest] = Enum.map(@vectors["exchange"], &frame(json(&1)))
    call_key = Base.decode16!(auth["keys"]["attempt_call_hex"], case: :lower)
    seal_key = Base.decode16!(auth["keys"]["attempt_seal_hex"], case: :lower)
    now = auth["call"]["ts"]

    assert byte_size(call.header) <= WorkerAuth.max_host_call_header_bytes()
    assert call.header =~ " "

    assert {:ok, fields, hash} =
             WorkerAuth.verify_host_call_header_under(call_key, call.header, now)

    assert fields.attempt == @attempt and fields.runner == auth["call"]["runner"]
    assert WorkerAuth.verify_body(hash, call.body) == :ok
    assert {:ok, json} = WorkerAuth.open_call(seal_key, :body, fields, call.body)
    assert {:ok, :egress_pin, _args} = WorkerWire.read_request_body(HostAPI, Jason.decode!(json))

    assert {:ok, pin} = WorkerAuth.open_call(seal_key, :answer, fields, answer.body)
    assert {:ok, wire} = pin |> Jason.decode!() |> WorkerWire.read_answer()
    assert {:ok, %PinnedTarget{id: id}} = PinnedTarget.read(wire)
    assert id == fetch.pin
  end

  test "a host call's header is printable ASCII up to the header's own bound" do
    runner = RunnerRelay.new(:runner, @attempt)
    call = %{kind: :host_call, attempt: @attempt, op: :renew, body: ""}
    longest = String.duplicate("a", WorkerAuth.max_host_call_header_bytes())

    assert {:ok, _bytes, _runner} = RunnerRelay.encode(runner, Map.put(call, :header, longest))

    for header <- [longest <> "a", "v1\tkind=call", "v1\nkind", "é"] do
      assert_raise ArgumentError, fn ->
        RunnerRelay.encode(runner, Map.put(call, :header, header))
      end
    end
  end

  test "the exchange encodes to its bytes and decodes to the frames sent" do
    channels = play(length(@vectors["exchange"]))
    assert channels.runner.calls == %{} and channels.service.calls == %{}
    assert channels.runner.fetches == %{} and channels.service.fetches == %{}
  end

  test "the exchange decodes as one buffer, split anywhere" do
    runner_bytes =
      @vectors["exchange"]
      |> Enum.filter(&(&1["from"] == "runner"))
      |> Enum.take(2)
      |> Enum.map_join(&encoded/1)

    service = RunnerRelay.new(:service, @attempt)
    cut = 7
    <<head::binary-size(^cut), tail::binary>> = runner_bytes
    assert {:ok, [], ^head, service} = RunnerRelay.decode(service, head)
    assert {:ok, [call, fetch], "", _service} = RunnerRelay.decode(service, head <> tail)
    assert call.kind == :host_call and call.op == :egress_pin and fetch.kind == :fetch
  end

  test "a fetch's credit is spent by chunks and granted again" do
    service = play(5).service
    assert RunnerRelay.credit(service, 1) == 0

    chunk = %{kind: :fetch_chunk, attempt: @attempt, re: 1, status: nil, headers: nil, body: "a"}
    assert RunnerRelay.encode(service, chunk) == {:error, :credit_exceeded}

    service = play(6).service
    assert RunnerRelay.credit(service, 1) == 1024
    too_much = %{chunk | body: String.duplicate("a", 1025)}
    assert RunnerRelay.encode(service, too_much) == {:error, :credit_exceeded}

    assert {:ok, _bytes, service} =
             RunnerRelay.encode(service, %{chunk | body: String.duplicate("a", 1024)})

    assert RunnerRelay.credit(service, 1) == 0
    assert RunnerRelay.credit(service, 99) == nil
  end

  for refusal <- @vectors["refusals"] do
    test "refused: #{refusal["why"]}" do
      refusal = unquote(Macro.escape(refusal))
      receiver = play(refusal["after"])[side(refusal["receiver"])]
      reason = String.to_existing_atom(refusal["reason"])
      assert RunnerRelay.decode(receiver, encoded(refusal)) == {:error, reason}
    end
  end

  test "the fixture's refusals are the channel's typed reasons" do
    reasons = Enum.map(@vectors["refusals"], & &1["reason"])

    assert Enum.sort(reasons) ==
             Enum.sort(
               ~w(unknown_attempt out_of_order body_too_large credit_exceeded frame_too_large wrong_direction)
             )
  end

  describe "the decoder's order" do
    defp one(side, object) do
      json = Jason.encode!(object)
      RunnerRelay.decode(RunnerRelay.new(side, @attempt), <<byte_size(json)::32, json::binary>>)
    end

    @call %{
      "v" => 1,
      "attempt" => @attempt,
      "seq" => 0,
      "kind" => "host_call",
      "op" => "renew",
      "header" => "h",
      "body" => ""
    }

    test "each refusal before the next" do
      json = "not json"

      assert RunnerRelay.decode(
               RunnerRelay.new(:service, @attempt),
               <<byte_size(json)::32, json::binary>>
             ) == {:error, :malformed}

      assert one(:service, %{@call | "v" => 2}) == {:error, :bad_version}
      assert one(:service, %{@call | "kind" => "exec"}) == {:error, :unknown_kind}
      assert one(:runner, @call) == {:error, :wrong_direction}
      assert one(:service, Map.put(@call, "extra", 1)) == {:error, {:unknown_field, "extra"}}
      assert one(:service, Map.delete(@call, "op")) == {:error, {:missing_field, "op"}}
      assert one(:service, %{@call | "seq" => "0"}) == {:error, {:wrong_type, "seq"}}
      assert one(:service, %{@call | "op" => "runner_exited"}) == {:error, {:invalid_field, "op"}}
      assert one(:service, %{@call | "body" => "!!"}) == {:error, {:invalid_field, "body"}}

      assert one(:service, %{@call | "attempt" => "", "seq" => 1}) ==
               {:error, {:invalid_field, "attempt"}}

      assert one(:service, %{@call | "seq" => 1, "attempt" => "att_other"}) ==
               {:error, :out_of_order}
    end

    test "an answer or a chunk naming nothing open" do
      answer = %{
        "v" => 1,
        "attempt" => @attempt,
        "seq" => 0,
        "kind" => "host_answer",
        "re" => 0,
        "status" => 200,
        "body" => ""
      }

      assert one(:runner, answer) == {:error, :unknown_reference}

      chunk = %{
        "v" => 1,
        "attempt" => @attempt,
        "seq" => 0,
        "kind" => "fetch_chunk",
        "re" => 0,
        "status" => 200,
        "headers" => [],
        "body" => ""
      }

      assert one(:runner, chunk) == {:error, :unknown_reference}
    end

    test "a chunk's head only on the first chunk of its fetch" do
      runner = play(3).runner

      headless = %{
        kind: :fetch_chunk,
        attempt: @attempt,
        re: 1,
        status: nil,
        headers: nil,
        body: ""
      }

      {:ok, bytes, _service} =
        RunnerRelay.encode(
          %{play(3).service | fetches: %{1 => %{attempt: @attempt, credit: 10, headed: true}}},
          headless
        )

      assert RunnerRelay.decode(runner, IO.iodata_to_binary(bytes)) ==
               {:error, {:invalid_field, "status"}}

      runner = play(4).runner
      headed = %{headless | status: 200, headers: []}

      {:ok, bytes, _service} =
        RunnerRelay.encode(
          %{play(4).service | fetches: %{1 => %{attempt: @attempt, credit: 10, headed: false}}},
          headed
        )

      assert RunnerRelay.decode(runner, IO.iodata_to_binary(bytes)) ==
               {:error, {:invalid_field, "status"}}
    end
  end

  describe "the channel's attempts" do
    test "a child attempt the channel admits is carried" do
      child = "att_01a09fee-0bbb-7ccc-8ddd-eeeeeeeeeeee"
      call = %{kind: :host_call, attempt: child, op: :renew, header: "h", body: ""}
      runner = RunnerRelay.new(:runner, @attempt)
      assert RunnerRelay.encode(runner, call) == {:error, :unknown_attempt}
      assert {:ok, bytes, _runner} = RunnerRelay.encode(RunnerRelay.admit(runner, child), call)

      service = RunnerRelay.new(:service, @attempt)
      bytes = IO.iodata_to_binary(bytes)
      assert RunnerRelay.decode(service, bytes) == {:error, :unknown_attempt}

      assert {:ok, [%{attempt: ^child}], "", _service} =
               RunnerRelay.decode(RunnerRelay.admit(service, child), bytes)
    end

    test "an answer names the call's own attempt" do
      child = "att_01a09fee-0bbb-7ccc-8ddd-eeeeeeeeeeee"
      service = RunnerRelay.new(:service, @attempt) |> RunnerRelay.admit(child)
      runner = RunnerRelay.new(:runner, @attempt) |> RunnerRelay.admit(child)

      {:ok, bytes, _runner} =
        RunnerRelay.encode(runner, %{
          kind: :host_call,
          attempt: @attempt,
          op: :renew,
          header: "h",
          body: ""
        })

      {:ok, _frames, "", service} = RunnerRelay.decode(service, IO.iodata_to_binary(bytes))
      answer = %{kind: :host_answer, attempt: child, re: 0, status: 200, body: ""}
      assert RunnerRelay.encode(service, answer) == {:error, :unknown_attempt}
    end
  end

  describe "the encoder" do
    test "raises on what the decoder refuses as malformed" do
      runner = RunnerRelay.new(:runner, @attempt)
      service = RunnerRelay.new(:service, @attempt)
      call = %{kind: :host_call, attempt: @attempt, op: :renew, header: "h", body: ""}

      for bad <- [
            %{call | op: :runner_exited},
            %{call | header: "has\ttab"},
            %{call | body: String.duplicate("a", RunnerRelay.max_body_bytes() + 1)},
            Map.delete(call, :op),
            Map.put(call, :seq, 0),
            Map.put(call, :extra, 1),
            %{call | attempt: ""},
            %{
              kind: :fetch,
              attempt: @attempt,
              pin: "not a pin",
              method: "GET",
              path: "/",
              headers: [],
              body: ""
            },
            %{
              kind: :fetch,
              attempt: @attempt,
              pin: "p",
              method: "TRACE",
              path: "/",
              headers: [],
              body: ""
            },
            %{
              kind: :fetch,
              attempt: @attempt,
              pin: "p",
              method: "GET",
              path: "relative",
              headers: [],
              body: ""
            },
            %{
              kind: :fetch,
              attempt: @attempt,
              pin: "p",
              method: "GET",
              path: "/",
              headers: [{"bad name", "v"}],
              body: ""
            },
            %{
              kind: :fetch,
              attempt: @attempt,
              pin: "p",
              method: "GET",
              path: "/",
              headers: [{"x", "a\nb"}],
              body: ""
            },
            %{kind: :credit, attempt: @attempt, re: 0, bytes: 0},
            %{kind: :close, attempt: @attempt, reason: "Not A Code"}
          ] do
        assert_raise ArgumentError, fn -> RunnerRelay.encode(runner, bad) end
      end

      assert_raise ArgumentError, fn -> RunnerRelay.encode(service, call) end

      assert_raise ArgumentError, fn ->
        RunnerRelay.encode(runner, %{kind: :exec, attempt: @attempt})
      end
    end

    test "a close carries a refusal's code" do
      assert RunnerRelay.close_code(:credit_exceeded) == "credit_exceeded"
      assert RunnerRelay.close_code({:unknown_field, "x"}) == "malformed"
      assert RunnerRelay.close_code(:done) == "done"
    end
  end
end
