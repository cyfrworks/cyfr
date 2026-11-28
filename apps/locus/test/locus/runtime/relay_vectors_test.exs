# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.RelayVectorsTest do
  @moduledoc """
  The service's end of a runner's relay (`Locus.Runtime.Relay`) plays the
  shared vectors (`tests/fixtures/runner_relay.json`, which Prima's codec
  test reads whole and the runner's crate plays as the runner,
  `apps/locus/runner/tests/vectors.rs`), bound to the vectors' own
  attempt with `tests/fixtures/worker_auth.json`'s assignment and keys:
  it closes the channel for each refusal whose receiver is the service,
  stopping with the refusal's reason and telling the runner its close
  code. Each code it ends a fetch with for a pin its own ask got none for
  is a code of the vectors, and its caps are theirs.
  """

  use ExUnit.Case, async: true

  alias Locus.Runtime.Relay

  @vectors Path.expand("../../../../../tests/fixtures/runner_relay.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  @auth Path.expand("../../../../../tests/fixtures/worker_auth.json", __DIR__)
        |> File.read!()
        |> Jason.decode!()

  @attempt @vectors["attempt"]

  # The fetch_end codes the service names: each `pin_` code is the one it
  # ends a fetch with for a pin its own ask got none for, by why; and the
  # service's two caps are Prima's.
  test "the vectors' pin codes are the service's for each pin it got none for, and the caps are Prima's" do
    pin_codes = for %{"code" => "pin_" <> _ = code} <- @vectors["codes"]["fetch_end"], do: code
    whys = Prima.PinnedTarget.refusals() ++ [:unavailable, :lost, :elsewhere, :expired]

    assert Enum.sort(pin_codes) == whys |> Enum.map(&Prima.RunnerRelay.pin_code/1) |> Enum.sort()

    assert Prima.RunnerRelay.max_calls() == @vectors["max_calls"]
    assert Prima.RunnerRelay.max_fetches() == @vectors["max_fetches"]
  end

  defp json(%{"json" => json}), do: json

  defp json(%{"json_fill" => %{"prefix" => p, "repeat" => r, "times" => n, "suffix" => s}}),
    do: p <> String.duplicate(r, n) <> s

  defp encoded(%{"encoded_hex" => hex}), do: Base.decode16!(hex, case: :lower)

  defp encoded(vector) do
    json = json(vector)
    <<byte_size(json)::32, json::binary>>
  end

  defp key(name), do: Base.decode16!(@auth["keys"][name], case: :lower)

  defp keys, do: %{call: key("attempt_call_hex"), seal: key("attempt_seal_hex")}

  # The refusals `receiver` receives: every refusal names a receiver, the
  # service or the runner (whose refusals the runner's crate plays), and
  # its frame, so none goes unread; `count` is how many it receives.
  defp refusals(receiver, count) do
    refusals = @vectors["refusals"]
    assert length(refusals) == 54

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
end
