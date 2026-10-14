# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.RelayVectorsTest do
  @moduledoc """
  The runtime's two ends of a runner's relay play the shared vectors
  (`tests/fixtures/runner_relay.json`, which Prima's codec test reads
  whole), bound to the vectors' own attempt.

  The service's end (`Locus.Runtime.Relay`), bound with
  `tests/fixtures/worker_auth.json`'s assignment and keys, closes the
  channel for each refusal whose receiver is the service: it stops with
  the refusal's reason and tells the runner its close code.

  The runner's end (`Locus.Runtime.Relay.Runner`) plays the exchange
  through its own API: every frame it sends for a call, a pinned fetch, a
  credit grant and an attached fetch is exactly the vector's bytes, and
  every frame the service sends reads as the event the vector names. It
  spends the initial credit and grants more only when asked, while an
  attached answer it reads is granted back whole as it reads it. Before
  each refusal whose receiver is the runner it plays the exchange's frames
  before it, and it closes the channel with the refusal's code.
  """

  use ExUnit.Case, async: true

  alias Locus.Runtime.Relay
  alias Locus.Runtime.Relay.Runner
  alias Prima.AttachedRequest

  @vectors Path.expand("../../../../../tests/fixtures/runner_relay.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  @auth Path.expand("../../../../../tests/fixtures/worker_auth.json", __DIR__)
        |> File.read!()
        |> Jason.decode!()

  @attempt @vectors["attempt"]

  # The seq of every attached fetch the exchange sends.
  @attached_fetches for %{"json" => json} <- @vectors["exchange"],
                        %{"kind" => "fetch", "connection" => _, "seq" => seq} <- [
                          Jason.decode!(json)
                        ],
                        do: seq

  defp json(%{"json" => json}), do: json

  defp json(%{"json_fill" => %{"prefix" => p, "repeat" => r, "times" => n, "suffix" => s}}),
    do: p <> String.duplicate(r, n) <> s

  defp encoded(%{"encoded_hex" => hex}), do: Base.decode16!(hex, case: :lower)

  defp encoded(vector) do
    json = json(vector)
    <<byte_size(json)::32, json::binary>>
  end

  defp object(vector), do: Jason.decode!(json(vector))

  defp key(name), do: Base.decode16!(@auth["keys"][name], case: :lower)

  defp keys, do: %{call: key("attempt_call_hex"), seal: key("attempt_seal_hex")}

  defp headers(headers), do: Enum.map(headers, &List.to_tuple/1)

  # The refusals `receiver` receives: every refusal names a receiver, the
  # service or the runner, and its frame, so none goes unread; `count` is
  # how many it receives.
  defp refusals(receiver, count) do
    refusals = @vectors["refusals"]
    assert length(refusals) == 13

    for refusal <- refusals do
      assert %{"why" => _, "receiver" => side, "after" => after_frames, "reason" => _} = refusal
      assert side in ["service", "runner"] and is_integer(after_frames), inspect(refusal)
      assert Enum.count(~w(json json_fill encoded_hex), &Map.has_key?(refusal, &1)) == 1
    end

    cases = Enum.filter(refusals, &(&1["receiver"] == receiver))
    assert length(cases) == count, "the #{receiver} receives #{length(cases)} refusals"
    cases
  end

  # The close code a refusal reaches the peer as: its reason, and for a
  # refusal naming a member, "malformed".
  defp close_code(%{"field" => field}) when is_binary(field), do: "malformed"
  defp close_code(%{"reason" => reason}), do: reason

  # One frame off the wire: its length and its JSON object.
  defp read_frame(<<length::32, json::binary-size(length)>>), do: Jason.decode!(json)

  describe "the service's end" do
    defp service_end! do
      test = self()
      assert @auth["attempt"]["attempt"] == @attempt

      relay =
        start_supervised!(
          {Relay,
           runner: @auth["call"]["runner"],
           write: fn data ->
             send(test, {:to_runner, IO.iodata_to_binary(data)})
             :ok
           end},
          id: make_ref()
        )

      attempt =
        Map.new(@auth["attempt"], fn {name, value} -> {String.to_existing_atom(name), value} end)

      assert :ok =
               Relay.bind(relay, %{
                 assignment: @auth["assignment"]["token"],
                 keys: Map.put(keys(), :attempt, attempt),
                 host_url: @auth["host_url"]
               })

      relay
    end

    # The reason the service stops with: an atom, or the atom and its member.
    defp stop_reason(%{"reason" => reason, "field" => field}),
      do: {String.to_existing_atom(reason), field}

    defp stop_reason(%{"reason" => reason}), do: String.to_existing_atom(reason)

    test "closes the channel for every refusal the service receives, naming its reason" do
      for refusal <- refusals("service", 8) do
        %{"why" => why, "after" => after_frames} = refusal

        # Every refusal a service receives is of a runner's first frame,
        # decided before any host call is made.
        assert after_frames == 0, why

        relay = service_end!()
        monitor = Process.monitor(relay)
        Relay.deliver(relay, encoded(refusal))

        expected = stop_reason(refusal)

        assert_receive {:DOWN, ^monitor, :process, ^relay, {:shutdown, {:closed, ^expected}}},
                       5_000

        assert_receive {:to_runner, bytes}, 1_000
        close = read_frame(bytes)

        assert %{"kind" => "close", "attempt" => @attempt, "reason" => code} = close, why
        assert code == close_code(refusal), why
        refute_received {:to_runner, _}, why
      end
    end
  end

  describe "the runner's end" do
    defp runner_end! do
      endpoint = start_supervised!({Runner, relay: {:peer, self()}}, id: make_ref())
      assert :ok = Runner.bind(endpoint, @attempt)
      endpoint
    end

    # The exchange's frames from `from` up to `to`: each runner frame sent
    # through the end's own API and received as exactly the vector's
    # bytes, each service frame handed to the end as the service would
    # write it. `played` carries the refs the end answered for the fetches
    # played so far, by the fetch frame's seq, and the calls it was asked.
    defp play(endpoint, from, to, played \\ %{refs: %{}, calls: []}) do
      @vectors["exchange"]
      |> Enum.slice(from, to - from)
      |> Enum.reduce(played, fn
        %{"from" => "service"} = vector, played ->
          send(endpoint, {:relay_in, encoded(vector)})
          played

        %{"from" => "runner"} = vector, played ->
          played = send_as_runner(endpoint, object(vector), played)
          assert_receive {:relay_in, bytes}, 5_000
          assert bytes == encoded(vector), vector["why"]
          played
      end)
    end

    defp send_as_runner(endpoint, %{"kind" => "host_call"} = frame, played) do
      %{"op" => op, "header" => header, "body" => body} = frame
      op = String.to_existing_atom(op)
      body = Base.decode64!(body)
      call = Task.async(fn -> Runner.call(endpoint, @attempt, op, header, body, 30_000) end)
      %{played | calls: [{frame["seq"], call} | played.calls]}
    end

    defp send_as_runner(endpoint, %{"kind" => "fetch", "pin" => pin} = frame, played) do
      %{"method" => method, "path" => path, "headers" => headers, "body" => body} = frame

      assert {:ok, ref} =
               Runner.fetch(
                 endpoint,
                 @attempt,
                 pin,
                 method,
                 path,
                 headers(headers),
                 Base.decode64!(body)
               )

      put_in(played.refs[frame["seq"]], ref)
    end

    defp send_as_runner(endpoint, %{"kind" => "fetch", "connection" => _} = frame, played) do
      request = %AttachedRequest{
        call_id: frame["call_id"],
        connection: frame["connection"],
        purpose: String.to_existing_atom(frame["purpose"]),
        method: frame["method"],
        url: frame["url"],
        headers: headers(frame["headers"]),
        body: Base.decode64!(frame["body"])
      }

      assert {:ok, ref} = Runner.attached_fetch(endpoint, @attempt, request, keys())
      put_in(played.refs[frame["seq"]], ref)
    end

    defp send_as_runner(endpoint, %{"kind" => "credit", "re" => re, "bytes" => bytes}, played) do
      Runner.credit(endpoint, Map.fetch!(played.refs, re), bytes)
      played
    end

    # What the end sent once a call to it was answered, which it answers
    # after every frame handed to it before.
    defp sent_since(endpoint) do
      _ = Runner.idle?(endpoint)
      drain([])
    end

    defp drain(frames) do
      receive do
        {:relay_in, bytes} -> drain([read_frame(bytes) | frames])
      after
        0 -> Enum.reverse(frames)
      end
    end

    test "plays the exchange through its API, up to the attached answer's end" do
      exchange = @vectors["exchange"]

      # The exchange runs on to a second attached fetch, its refusal and a
      # close of the runner's own. From the first attached answer on, the
      # end grants back what it reads, which a codec's exchange does not
      # show, so its later frames' seq follows those grants; the refusal's
      # header is signed at the vector's time, which no clock now admits;
      # and the end sends no close but a refusal's.
      [end_of_first] =
        for {vector, index} <- Enum.with_index(exchange),
            %{"kind" => "fetch_end", "re" => re} <- [object(vector)],
            re == hd(@attached_fetches),
            do: index

      endpoint = runner_end!()
      played = play(endpoint, 0, end_of_first + 1)

      # The call was answered with the vector's status and body.
      answer = object(Enum.at(exchange, 1))
      assert [{0, call}] = played.calls
      assert Task.await(call) == {:ok, answer["status"], Base.decode64!(answer["body"])}

      # Nothing is open: the call is answered and both fetches have ended.
      assert Runner.idle?(endpoint)

      # The pinned fetch's answer, read as the service's frames carried it:
      # its head, each chunk in order, and its end.
      pinned_seq = object(Enum.at(exchange, 2))["seq"]
      pinned = played.refs[pinned_seq]

      [head | chunks] =
        for v <- exchange,
            %{"kind" => "fetch_chunk", "re" => re} = chunk <- [object(v)],
            re == pinned_seq,
            do: chunk

      assert_received {Runner, ^pinned, {:head, status, head_headers, body}}

      assert {status, head_headers, body} ==
               {head["status"], headers(head["headers"]), Base.decode64!(head["body"])}

      for chunk <- chunks do
        assert_received {Runner, ^pinned, {:chunk, body}}
        assert body == Base.decode64!(chunk["body"])
      end

      assert_received {Runner, ^pinned, {:end, nil}}

      # The attached answer opened whole under the vectors' keys, and every
      # byte of it was granted back as it was read.
      attached = played.refs[hd(@attached_fetches)]
      assert_received {Runner, ^attached, {:end, nil}}

      relayed =
        for v <- exchange,
            %{"kind" => "attached_frame", "re" => re, "frame" => frame} <- [object(v)],
            re == hd(@attached_fetches),
            do: byte_size(Base.decode64!(frame))

      grants = sent_since(endpoint)
      first_attached = hd(@attached_fetches)

      assert Enum.all?(grants, &match?(%{"kind" => "credit", "re" => ^first_attached}, &1)),
             inspect(grants)

      assert grants |> Enum.map(& &1["bytes"]) |> Enum.sum() == Enum.sum(relayed)
    end

    test "spends the initial credit, then grants exactly what it is asked to" do
      exchange = @vectors["exchange"]

      # The first five frames carry the initial credit's bytes in chunks,
      # the sixth is the runner's grant.
      spent =
        for v <- Enum.take(exchange, 5),
            %{"kind" => "fetch_chunk", "body" => body} <- [object(v)],
            do: byte_size(Base.decode64!(body))

      assert Enum.sum(spent) == @vectors["initial_credit"]
      assert %{"kind" => "credit"} = object(Enum.at(exchange, 5))

      endpoint = runner_end!()
      played = play(endpoint, 0, 5)

      # Spent, the end grants nothing of itself.
      assert sent_since(endpoint) == []

      # Asked for more, it sends the vector's credit frame.
      play(endpoint, 5, 6, played)
    end

    test "closes the channel for every refusal the runner receives, after the exchange's frames before it" do
      for refusal <- refusals("runner", 5) do
        %{"why" => why, "after" => after_frames} = refusal
        endpoint = runner_end!()
        played = play(endpoint, 0, after_frames)

        send(endpoint, {:relay_in, encoded(refusal)})

        # What it sent after: any grant of an attached answer it read, then
        # the close, and nothing after the close.
        {grants, [close]} =
          endpoint |> sent_since() |> Enum.split_while(&(&1["kind"] == "credit"))

        for grant <- grants, do: assert(grant["re"] in @attached_fetches, why)

        assert %{"kind" => "close", "attempt" => @attempt, "reason" => code} = close, why
        assert code == close_code(refusal), why

        # Every host call it made was answered before the refusal.
        for {_seq, call} <- played.calls, do: assert({:ok, 200, _body} = Task.await(call), why)
      end
    end
  end
end
