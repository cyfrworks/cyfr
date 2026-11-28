# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.RunnerRelayTest do
  @moduledoc """
  The runner relay codec reproduces the shared vectors
  (`tests/fixtures/runner_relay.json`, which Locus's relay vectors test
  plays against the runtime's runner and worker-service ends too): the
  exchange, played between a runner's channel and a service's, encodes
  every frame to exactly its bytes and decodes each to the frame sent, one
  example of every kind among them and a fetch whose initial credit is
  spent and granted again; every refusal closes the channel with its
  reason. The bounds are the fixture's and
  `Prima.HostAPI`'s. The service's channel never encodes a chunk past the
  credit outstanding, and the encoder raises on what the decoder would
  refuse as malformed.

  An attached fetch names its connection and call id and no pin, a pinned
  one a pin and no connection; one naming both or neither is refused. Its
  answers are the frames CYFR sealed for its call id, or the refusal CYFR
  answered the service's `attached_fetch` call with, each verifiable by
  the runner, and only an attached fetch takes them.
  """

  use ExUnit.Case, async: true

  alias Prima.{AttachedRequest, HostAPI, PinnedTarget, RunnerRelay, WorkerAuth, WorkerWire}

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
      {"frame", frame} -> {:frame, Base.decode64!(frame)}
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
    assert AttachedRequest.max_headers() == @vectors["max_headers"]
    assert AttachedRequest.max_header_name_bytes() == @vectors["max_header_name_bytes"]
    assert AttachedRequest.max_header_value_bytes() == @vectors["max_header_value_bytes"]
    assert WorkerAuth.max_host_call_header_bytes() == @vectors["max_signed_header_bytes"]
    assert WorkerAuth.max_frame_bytes() == @vectors["max_attached_frame_bytes"]
    assert Enum.map(RunnerRelay.ops(), &Atom.to_string/1) == @vectors["ops"]
    assert Prima.Destination.methods() == @vectors["methods"]
    assert Enum.map(AttachedRequest.purposes(), &Atom.to_string/1) == @vectors["purposes"]
    assert AttachedRequest.max_url_bytes() == @vectors["max_url_bytes"]
    # The largest body in base64 fits a frame with room for its envelope.
    assert div(RunnerRelay.max_body_bytes() + 2, 3) * 4 + 65_536 < RunnerRelay.max_frame_bytes()
  end

  test "what a service holds of the frames it writes is the fixture's counted" do
    counted = @vectors["counted"]
    %{"bodies" => bodies, "pieces" => pieces, "refusals" => refusals} = counted
    assert length(bodies) >= 8 and length(pieces) >= 6 and length(refusals) >= 3

    assert RunnerRelay.envelope_bytes() === counted["envelope_bytes"]
    assert RunnerRelay.chunk_bytes() === counted["chunk_bytes"]
    assert RunnerRelay.answer_room() === counted["answer_room"]

    assert Prima.LocusRoles.role!(:runtime).memory.fetch_read_ahead_bytes ===
             counted["read_ahead_bytes"]

    assert RunnerRelay.piece_held(counted["read_ahead_bytes"]) === counted["read_ahead_room"]

    for %{"bytes" => bytes, "frames" => frames, "held" => held} <- bodies,
        do: assert(RunnerRelay.held(bytes, frames) === held, "#{bytes} bytes in #{frames}")

    for %{"bytes" => bytes, "held" => held} <- pieces,
        do: assert(RunnerRelay.piece_held(bytes) === held, "a piece of #{bytes} bytes")

    for %{"bytes" => bytes, "held" => held} <- refusals,
        do: assert(RunnerRelay.refusal_held(bytes) === held, "a refusal of #{bytes} bytes")
  end

  test "the caps and the codes are the fixture's" do
    assert RunnerRelay.max_calls() == @vectors["max_calls"]
    assert RunnerRelay.max_fetches() == @vectors["max_fetches"]

    pairs = fn section ->
      Enum.map(@vectors["codes"][section], &{&1["code"], &1["why"]})
    end

    assert RunnerRelay.fetch_end_codes() == pairs.("fetch_end")
    assert RunnerRelay.close_codes() == pairs.("close")

    # Every code is of the form decoding holds it to.
    for {code, _why} <- RunnerRelay.fetch_end_codes() ++ RunnerRelay.close_codes(),
        do: assert(code =~ ~r/\A[a-z][a-z0-9_]{0,63}\z/, code)

    # A pin code for each of CYFR's refusals and the service's own, read
    # back to its why; any other reason is a lost answer.
    whys = Prima.PinnedTarget.refusals() ++ [:unavailable, :lost, :elsewhere, :expired]

    for why <- whys do
      code = RunnerRelay.pin_code(why)
      assert {code, _} = List.keyfind(RunnerRelay.fetch_end_codes(), code, 0)
      assert RunnerRelay.pin_why(code) == {:ok, why}
    end

    assert RunnerRelay.pin_code(:anything_else) == "pin_lost"
    assert RunnerRelay.pin_why("timeout") == :error
  end

  test "a channel closes with a code of the roster, and with no other" do
    assert RunnerRelay.close_code(:too_many_fetches) == "too_many_fetches"
    assert RunnerRelay.close_code({:missing_field, "seq"}) == "malformed"
    assert_raise ArgumentError, fn -> RunnerRelay.close_code(:not_a_code) end

    # Every refusal the decoder answers has its code.
    for refusal <- @vectors["refusals"] do
      code = refusal |> reason() |> RunnerRelay.close_code()
      assert List.keymember?(RunnerRelay.close_codes(), code, 0), refusal["why"]
    end
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

  # A reason, with the member it names when it names one.
  defp reason(%{"reason" => reason, "field" => field}),
    do: {String.to_existing_atom(reason), field}

  defp reason(%{"reason" => reason}), do: String.to_existing_atom(reason)

  for refusal <- @vectors["refusals"] do
    test "refused: #{refusal["why"]}" do
      refusal = unquote(Macro.escape(refusal))
      receiver = play(refusal["after"])[side(refusal["receiver"])]
      assert RunnerRelay.decode(receiver, encoded(refusal)) == {:error, reason(refusal)}
    end
  end

  # Each frame a runner's channel refuses to send: the member it names, or
  # what the channel's state does not take, before anything is numbered.
  for {refusal, index} <- Enum.with_index(@vectors["encode_refusals"]) do
    test "not sent: #{refusal["why"]}" do
      refusal = Enum.at(@vectors["encode_refusals"], unquote(index))
      runner = play(refusal["after"]).runner
      sent = frame(Jason.encode!(refusal["frame"]))

      case refusal do
        %{"member" => member} ->
          assert_raise ArgumentError, ~r/\A#{member} is not of its type or bound\z/, fn ->
            RunnerRelay.encode(runner, sent)
          end

        %{"reason" => reason} ->
          assert RunnerRelay.encode(runner, sent) == {:error, String.to_existing_atom(reason)}
      end
    end
  end

  test "the encoder's refusals name members of every kind a runner sends" do
    kinds =
      for %{"frame" => %{"kind" => kind}} <- @vectors["encode_refusals"], uniq: true, do: kind

    assert Enum.sort(kinds) == ~w(close credit fetch host_call)
  end

  test "a pinned fetch's path is held to the fixture's bound" do
    runner = play(2).runner
    [_call, _answer, fetch | _rest] = Enum.map(@vectors["exchange"], &frame(json(&1)))
    at_bound = %{fetch | path: "/" <> String.duplicate("a", @vectors["max_path_bytes"] - 1)}
    assert {:ok, _bytes, _runner} = RunnerRelay.encode(runner, at_bound)
  end

  test "the fixture's refusals are the channel's typed reasons" do
    reasons = Enum.map(@vectors["refusals"], &reason/1)

    # Every typed reason closes a channel in some refusal, and the runner's
    # half of the refusals meets every one of them.
    assert reasons |> Enum.map(&reason_name/1) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort(~w(frame_too_large malformed bad_version unknown_kind wrong_direction
                          unknown_field missing_field wrong_type invalid_field body_too_large
                          out_of_order unknown_attempt unknown_reference wrong_answer
                          credit_exceeded)a)

    runner =
      for %{"receiver" => "runner"} = refusal <- @vectors["refusals"],
          uniq: true,
          do: reason_name(reason(refusal))

    assert Enum.sort(runner) == Enum.sort(Enum.map(reasons, &reason_name/1) |> Enum.uniq())
  end

  defp reason_name({name, _field}), do: name
  defp reason_name(name), do: name

  describe "an attached fetch" do
    defp host_api,
      do:
        Path.expand("../../../../tests/fixtures/host_api.json", __DIR__)
        |> File.read!()
        |> Jason.decode!()

    defp frames_of(kind),
      do:
        @vectors["exchange"]
        |> Enum.map(&frame(json(&1)))
        |> Enum.filter(&(&1.kind == kind))

    test "names its connection and call id and no pin, and the service posts it member for member" do
      [_pinned, attached, refused_fetch] = frames_of(:fetch)
      assert Map.has_key?(attached, :connection) and not Map.has_key?(attached, :pin)
      refute Map.has_key?(attached, :path)
      assert AttachedRequest.valid_call_id?(attached.call_id)

      # The service's conversion: the relay body decoded, sent as base64.
      request = %AttachedRequest{
        call_id: refused_fetch.call_id,
        connection: refused_fetch.connection,
        method: refused_fetch.method,
        url: refused_fetch.url,
        headers: refused_fetch.headers,
        body: refused_fetch.body,
        purpose: String.to_existing_atom(refused_fetch.purpose)
      }

      [call] = Enum.filter(host_api()["calls"], &(&1["callback"] == "attached_fetch"))
      %{"args" => args} = Jason.decode!(call["body"])
      assert AttachedRequest.to_args(request) == args
      assert args["body_encoding"] == "base64"
    end

    test "its frames open for its call id, in order, as CYFR sealed them" do
      auth =
        Path.expand("../../../../tests/fixtures/worker_auth.json", __DIR__)
        |> File.read!()
        |> Jason.decode!()

      seal = Base.decode16!(auth["keys"]["attempt_seal_hex"], case: :lower)
      [_pinned, attached, _refused] = frames_of(:fetch)

      read =
        :attached_frame
        |> frames_of()
        |> Enum.map_reduce(WorkerAuth.frame_reader(seal, attached.call_id), fn frame, reader ->
          {:ok, read, reader} = WorkerAuth.read_frame(reader, frame.frame)
          {read.kind, reader}
        end)

      assert {[:head, :chunk, :end], %{state: :done}} = read
    end

    test "its refusal verifies under the attempt's call key and names its call id" do
      auth =
        Path.expand("../../../../tests/fixtures/worker_auth.json", __DIR__)
        |> File.read!()
        |> Jason.decode!()

      call_key = Base.decode16!(auth["keys"]["attempt_call_hex"], case: :lower)
      seal = Base.decode16!(auth["keys"]["attempt_seal_hex"], case: :lower)
      [_pinned, _attached, refused_fetch] = frames_of(:fetch)
      [refusal] = frames_of(:attached_refusal)
      [call] = Enum.filter(host_api()["calls"], &(&1["callback"] == "attached_fetch"))

      assert refusal.header == call["header"]

      assert {:ok, fields, _hash} =
               WorkerAuth.verify_host_call_header_under(
                 call_key,
                 refusal.header,
                 call["fields"]["ts"]
               )

      assert fields.attempt == @attempt
      assert {:ok, answer} = WorkerAuth.open_call(seal, :answer, fields, refusal.body)

      assert {:error, "guest_error", %{"call_id" => call_id, "type" => "destination_mismatch"}} =
               answer |> Jason.decode!() |> WorkerWire.read_answer()

      assert call_id == refused_fetch.call_id
    end

    test "both a pin and a connection, or neither, never encode" do
      runner = RunnerRelay.new(:runner, @attempt)

      attached = %{
        kind: :fetch,
        attempt: @attempt,
        call_id: "AAECAwQFBgcICQoLDA0ODw",
        connection: "api_key",
        purpose: "fetch",
        method: "GET",
        url: "https://api.example.com/v1",
        headers: [],
        body: ""
      }

      assert {:ok, _bytes, _runner} = RunnerRelay.encode(runner, attached)

      for bad <- [
            Map.put(attached, :pin, "pin_1"),
            Map.put(attached, :path, "/v1"),
            %{attached | call_id: "AAECAwQFBgcICQoLDA0OD"},
            %{attached | call_id: "AAECAwQFBgcICQoLDA0ODx"},
            %{attached | connection: "Api_Key"},
            %{attached | purpose: "redirect"},
            %{attached | url: "ftp://api.example.com/"},
            %{attached | url: "/v1/relative"},
            attached |> Map.drop([:connection, :call_id, :purpose, :url]),
            %{
              kind: :fetch,
              attempt: @attempt,
              pin: "pin_1",
              method: "GET",
              path: "/",
              headers: [],
              body: "",
              url: "https://api.example.com/"
            }
          ] do
        assert_raise ArgumentError, fn -> RunnerRelay.encode(runner, bad) end
      end
    end

    test "is answered by frames within its credit, never by chunks, a pinned one never by frames" do
      runner = RunnerRelay.new(:runner, @attempt)
      service = RunnerRelay.new(:service, @attempt)

      attached = %{
        kind: :fetch,
        attempt: @attempt,
        call_id: "AAECAwQFBgcICQoLDA0ODw",
        connection: "api_key",
        purpose: "stream",
        method: "POST",
        url: "https://api.example.com/v1",
        headers: [],
        body: "{}"
      }

      {:ok, bytes, _runner} = RunnerRelay.encode(runner, attached)
      {:ok, [_fetch], "", service} = RunnerRelay.decode(service, IO.iodata_to_binary(bytes))
      assert RunnerRelay.credit(service, 0) == RunnerRelay.initial_credit()

      frame = %{
        kind: :attached_frame,
        attempt: @attempt,
        re: 0,
        frame: "h" <> String.duplicate("a", 99)
      }

      assert {:ok, _bytes, service} = RunnerRelay.encode(service, frame)
      assert RunnerRelay.credit(service, 0) == RunnerRelay.initial_credit() - 100

      chunk = %{kind: :fetch_chunk, attempt: @attempt, re: 0, status: 200, headers: [], body: ""}
      assert RunnerRelay.encode(service, chunk) == {:error, :wrong_answer}

      refusal = %{kind: :attached_refusal, attempt: @attempt, re: 0, header: "h", body: "x"}
      assert RunnerRelay.encode(service, refusal) == {:error, :wrong_answer}

      spent = %{service | fetches: %{0 => %{service.fetches[0] | credit: 10}}}
      assert RunnerRelay.encode(spent, frame) == {:error, :credit_exceeded}

      # A frame past the answer frame bound, or of no sealed value, is not a frame.
      for bad <- ["h", "h" <> String.duplicate("a", WorkerAuth.max_frame_bytes())] do
        assert_raise ArgumentError, fn -> RunnerRelay.encode(service, %{frame | frame: bad}) end
      end
    end

    test "a refusal comes before any frame, and no frame after it" do
      runner = RunnerRelay.new(:runner, @attempt)
      service = RunnerRelay.new(:service, @attempt)

      attached = %{
        kind: :fetch,
        attempt: @attempt,
        call_id: "AAECAwQFBgcICQoLDA0ODw",
        connection: "api_key",
        purpose: "fetch",
        method: "GET",
        url: "https://api.example.com/v1",
        headers: [],
        body: ""
      }

      {:ok, bytes, _runner} = RunnerRelay.encode(runner, attached)
      {:ok, [_fetch], "", service} = RunnerRelay.decode(service, IO.iodata_to_binary(bytes))

      refusal = %{kind: :attached_refusal, attempt: @attempt, re: 0, header: "h", body: "x"}
      assert {:ok, _bytes, refused} = RunnerRelay.encode(service, refusal)

      frame = %{kind: :attached_frame, attempt: @attempt, re: 0, frame: "hh"}
      assert RunnerRelay.encode(refused, frame) == {:error, :wrong_answer}
      assert RunnerRelay.encode(refused, refusal) == {:error, :wrong_answer}

      assert {:ok, _bytes, _service} =
               RunnerRelay.encode(refused, %{
                 kind: :fetch_end,
                 attempt: @attempt,
                 re: 0,
                 error: "refused"
               })
    end

    test "a runner's host call never names attached_fetch: the service posts it" do
      refute :attached_fetch in RunnerRelay.ops()
      refute :runner_exited in RunnerRelay.ops()
      assert :attached_fetch in HostAPI.callbacks()
      assert :attached_frame in RunnerRelay.kinds() and :attached_refusal in RunnerRelay.kinds()
      assert RunnerRelay.sender(:attached_frame) == :service
      assert RunnerRelay.sender(:attached_refusal) == :service
    end
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
          %{play(3).service | fetches: %{1 => pinned_fetch(headed: true)}},
          headless
        )

      assert RunnerRelay.decode(runner, IO.iodata_to_binary(bytes)) ==
               {:error, {:invalid_field, "status"}}

      runner = play(4).runner
      headed = %{headless | status: 200, headers: []}

      {:ok, bytes, _service} =
        RunnerRelay.encode(
          %{play(4).service | fetches: %{1 => pinned_fetch(headed: false)}},
          headed
        )

      assert RunnerRelay.decode(runner, IO.iodata_to_binary(bytes)) ==
               {:error, {:invalid_field, "status"}}
    end
  end

  # A pinned fetch's state on a channel, as `encode/2` and `decode/2` keep it.
  defp pinned_fetch(headed: headed),
    do: %{attempt: @attempt, mode: :pin, credit: 10, headed: headed, refused: false}

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

  describe "a host answer's body" do
    test "at its bound fits the frame of the longest attempt" do
      longest = String.duplicate(~s("), 256)
      runner = RunnerRelay.new(:runner, longest)
      service = RunnerRelay.new(:service, longest)
      call = %{kind: :host_call, attempt: longest, op: :fetch_artifact, header: "h", body: ""}
      {:ok, bytes, _runner} = RunnerRelay.encode(runner, call)
      {:ok, _frames, "", service} = RunnerRelay.decode(service, IO.iodata_to_binary(bytes))

      max = RunnerRelay.max_answer_body_bytes()
      assert max <= RunnerRelay.max_body_bytes()
      body = :binary.copy("a", max)

      assert {:ok, [<<length::32>>, _json], _service} =
               RunnerRelay.encode(service, %{
                 kind: :host_answer,
                 attempt: longest,
                 re: 0,
                 status: 200,
                 body: body
               })

      assert length <= RunnerRelay.max_frame_bytes()
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

    test "a fetch's head is held to the attached request's bounds, at them and one past" do
      runner = RunnerRelay.new(:runner, @attempt)
      url = "https://api.example.com/"
      name = String.duplicate("n", AttachedRequest.max_header_name_bytes())
      value = String.duplicate("v", AttachedRequest.max_header_value_bytes())

      at_bounds = %{
        kind: :fetch,
        attempt: @attempt,
        call_id: "AAECAwQFBgcICQoLDA0ODw",
        connection: "api_key",
        purpose: "fetch",
        method: "GET",
        url: url <> String.duplicate("a", AttachedRequest.max_url_bytes() - byte_size(url)),
        headers: [{name, value} | List.duplicate({"x", "y"}, AttachedRequest.max_headers() - 1)],
        body: ""
      }

      assert {:ok, _bytes, _runner} = RunnerRelay.encode(runner, at_bounds)

      for over <- [
            %{at_bounds | url: at_bounds.url <> "a"},
            %{at_bounds | headers: [{"x", "y"} | at_bounds.headers]},
            %{at_bounds | headers: [{name <> "n", "v"}]},
            %{at_bounds | headers: [{"x", value <> "v"}]}
          ] do
        assert_raise ArgumentError, fn -> RunnerRelay.encode(runner, over) end
      end
    end

    test "a close carries a refusal's code" do
      assert RunnerRelay.close_code(:credit_exceeded) == "credit_exceeded"
      assert RunnerRelay.close_code({:unknown_field, "x"}) == "malformed"
      assert RunnerRelay.close_code(:done) == "done"
    end
  end
end
