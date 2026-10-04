# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.FeedTest do
  @moduledoc """
  Feeds against `tests/fixtures/feed.json`: every valid binding reads and
  writes back to itself, every refused binding is refused at its path for
  its reason, the inputs, crons, results and envelopes are the fixture's,
  and a binding id has its grammar. Beside them, the byte bounds of a
  feed's JSON text, checked before the shape, and the envelope's refusal
  to carry anything but the binding's display part.
  """

  use ExUnit.Case, async: true

  alias Prima.Feed
  alias Prima.Feed.{Action, Binding}

  @vectors Path.expand("../../../../tests/fixtures/feed.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp bindings do
    for %{"binding" => json} <- vectors()["bindings"]["valid"] do
      {:ok, binding} = Binding.validate(json)
      binding
    end
  end

  defp json_binding(shape) do
    {:ok, binding} =
      Binding.validate(%{
        "name" => "sized",
        "label" => "Sized",
        "reference" => "catalyst:local.sized",
        "operation" => "read",
        "args" => %{},
        "interval_minutes" => 1,
        "result_shape" => shape,
        "actions" => []
      })

    binding
  end

  describe "the fixture" do
    test "the intervals, bounds and reasons are the module's" do
      v = vectors()
      assert v["intervals"] == Feed.intervals()
      assert v["args_max_bytes"] == Feed.args_max_bytes()
      assert v["result_max_bytes"] == Feed.result_max_bytes()
      assert v["reasons"] == Feed.reasons()

      assert Map.take(Feed.reasons(), Map.keys(Prima.Canvas.Shape.reasons())) ==
               Prima.Canvas.Shape.reasons()
    end

    test "every valid binding reads, writes back to its JSON and reads back to itself" do
      for %{"binding" => json, "json" => written} <- vectors()["bindings"]["valid"] do
        assert {:ok, %Binding{} = binding} = Binding.validate(json)
        assert Binding.to_json(binding) == written
        assert Binding.validate(Binding.to_json(binding)) == {:ok, binding}
        assert Enum.all?(binding.actions, &(&1.kind in [:refresh, :run]))
      end
    end

    test "every refused binding is refused at its path for its reason" do
      reasons = Map.keys(Feed.reasons())

      for %{"why" => why, "binding" => json, "path" => path, "reason" => reason} <-
            vectors()["bindings"]["invalid"] do
        assert reason in reasons, why
        assert Binding.validate(json) == {:error, %{path: path, reason: reason}}, why
      end
    end

    test "a binding id is feed_ and a lowercase UUID v7" do
      %{"valid" => valid, "invalid" => invalid} = vectors()["binding_ids"]

      for id <- valid, do: assert(Feed.binding_id?(id), id)
      for %{"why" => why, "id" => id} <- invalid, do: refute(Feed.binding_id?(id), why)

      for _ <- 1..20, do: assert(Feed.binding_id?(Prima.UUID7.generate_id("feed")))
      refute Feed.binding_id?(nil)
      refute Feed.binding_id?(Prima.UUID7.generate_id("feed") <> "\n")
    end

    test "a binding and a run action run with their operation and args as params" do
      bindings = bindings()

      for %{"why" => why, "binding" => index, "input" => input} = row <- vectors()["inputs"] do
        binding = Enum.at(bindings, index)

        source =
          case row do
            %{"action" => action} -> Enum.at(binding.actions, action)
            _ -> binding
          end

        assert Feed.input(source) == input, why
      end

      [btc | _] = bindings
      refresh = Enum.find(btc.actions, &(&1.kind == :refresh))
      assert_raise FunctionClauseError, fn -> Feed.input(refresh) end
    end

    test "each interval's cron expression" do
      [btc | _] = bindings()

      for %{"interval_minutes" => minutes, "cron" => cron} <- vectors()["crons"] do
        assert Feed.cron(%{btc | interval_minutes: minutes}) == cron
      end

      assert Enum.map(vectors()["crons"], & &1["interval_minutes"]) == Feed.intervals()
    end

    test "every result is accepted or refused at its path for its reason" do
      bindings = bindings()

      for %{"binding" => index, "valid" => valid, "invalid" => invalid} <- vectors()["results"] do
        binding = Enum.at(bindings, index)

        for result <- valid, do: assert(Feed.check_result(binding, result) == :ok)

        for %{"why" => why, "result" => result, "path" => path, "reason" => reason} <- invalid do
          assert Feed.check_result(binding, result) == {:error, %{path: path, reason: reason}},
                 why
        end
      end
    end

    test "every envelope is the fixture's" do
      bindings = bindings()

      for %{"why" => why, "binding_id" => id, "binding" => index} = row <- vectors()["envelopes"] do
        {:ok, at, _offset} = DateTime.from_iso8601(row["at"])
        binding = Enum.at(bindings, index)

        assert Feed.envelope(id, binding, row["revision"], at, row["result"]) == row["envelope"],
               why
      end
    end
  end

  describe "the bounds" do
    test "a result is at most 65536 bytes of JSON text, checked before its shape" do
      binding =
        json_binding(%{"type" => "object", "fields" => %{"s" => %{"type" => "json"}}})

      at_bound = %{"s" => String.duplicate("a", 65_528)}
      past_bound = %{"s" => String.duplicate("a", 65_529)}
      assert byte_size(Jason.encode!(at_bound)) == 65_536
      assert byte_size(Jason.encode!(past_bound)) == 65_537

      assert Feed.check_result(binding, at_bound) == :ok
      assert Feed.check_result(binding, past_bound) == {:error, %{path: "", reason: "size"}}

      # Past the bound and outside the shape: the size is the refusal.
      outside = %{"t" => String.duplicate("a", 65_529)}
      assert Feed.check_result(binding, outside) == {:error, %{path: "", reason: "size"}}

      assert Feed.check_result(binding, %{"t" => 1}) ==
               {:error, %{path: "/t", reason: "unknown_field"}}
    end

    test "a result JSON text cannot be written for is refused as json" do
      binding = json_binding(%{"type" => "json", "nullable" => true})

      for result <- [<<0xFF>>, %{"s" => <<0xFF>>}, {:a, 1}, self(), [:atom]] do
        assert Feed.check_result(binding, result) == {:error, %{path: "", reason: "json"}},
               inspect(result)
      end

      for result <- [nil, 2.5, [1, nil, -0.25], %{"a" => nil}] do
        assert Feed.check_result(binding, result) == :ok, inspect(result)
      end
    end

    test "args are at most 4096 bytes of JSON text, and may hold floats and nulls" do
      [btc | _] = vectors()["bindings"]["valid"] |> Enum.map(& &1["binding"])

      at_bound = %{"pad" => String.duplicate("x", 4086)}
      assert byte_size(Jason.encode!(at_bound)) == 4096
      assert {:ok, %Binding{args: ^at_bound}} = Binding.validate(%{btc | "args" => at_bound})

      past_bound = %{"pad" => String.duplicate("x", 4087)}

      assert Binding.validate(%{btc | "args" => past_bound}) ==
               {:error, %{path: "/args", reason: "size"}}

      floats = %{"depth" => 2.5, "venue" => nil, "levels" => [0.1, nil]}
      assert {:ok, %Binding{args: ^floats}} = Binding.validate(%{btc | "args" => floats})

      assert Binding.validate(%{btc | "args" => %{"bad" => <<0xFF>>}}) ==
               {:error, %{path: "/args", reason: "json"}}
    end

    test "a binding takes 8 actions and no more" do
      [btc | _] = vectors()["bindings"]["valid"] |> Enum.map(& &1["binding"])
      actions = for i <- 1..9, do: %{"name" => "a#{i}", "label" => "A#{i}", "kind" => "refresh"}

      assert {:ok, %Binding{actions: eight}} =
               Binding.validate(%{btc | "actions" => Enum.take(actions, 8)})

      assert length(eight) == 8

      assert Binding.validate(%{btc | "actions" => actions}) ==
               {:error, %{path: "/actions", reason: "range"}}
    end

    test "labels are counted in code points" do
      [btc | _] = vectors()["bindings"]["valid"] |> Enum.map(& &1["binding"])

      assert {:ok, _} = Binding.validate(%{btc | "label" => String.duplicate("é", 80)})

      action = %{"name" => "go", "label" => String.duplicate("é", 40), "kind" => "refresh"}
      assert {:ok, %Action{kind: :refresh, operation: nil, args: nil}} = Action.validate(action)

      assert Action.validate(%{action | "label" => String.duplicate("é", 41)}) ==
               {:error, %{path: "/label", reason: "text"}}
    end

    test "an action's kind is an atom in the struct and a string in JSON" do
      run = %{
        "name" => "buy",
        "label" => "Buy",
        "kind" => "run",
        "operation" => "order",
        "args" => %{}
      }

      assert {:ok, %Action{kind: :run, operation: "order", args: %{}} = action} =
               Action.validate(run)

      assert Action.to_json(action) == run

      assert Action.validate(%{run | "kind" => :run}) ==
               {:error, %{path: "/kind", reason: "type"}}
    end
  end

  describe "the envelope" do
    setup do
      [btc | _] = bindings()
      %{btc: btc, at: ~U[2026-10-04 12:00:00Z]}
    end

    test "carries exactly the binding id, the feed, the revision, the time, the result and the display part",
         %{btc: btc, at: at} do
      id = Prima.UUID7.generate_id("feed")
      envelope = Feed.envelope(id, btc, 3, at, %{"price" => 1})

      assert envelope |> Map.keys() |> Enum.sort() ==
               ~w(actions at binding feed label result revision)

      assert envelope["binding"] == id
      assert envelope["feed"] == btc.name

      assert envelope["actions"] ==
               Enum.map(btc.actions, &%{"name" => &1.name, "label" => &1.label})

      text = Jason.encode!(envelope)
      refute text =~ btc.reference
      refute text =~ ~s("args")
      refute text =~ ~s("operation")
      refute text =~ ~s("interval_minutes")
      refute text =~ "depth"
    end

    test "is refused without a binding id or with a negative revision", %{btc: btc, at: at} do
      assert_raise ArgumentError, fn -> Feed.envelope(nil, btc, 1, at, %{}) end
      assert_raise ArgumentError, fn -> Feed.envelope("btc", btc, 1, at, %{}) end
      assert_raise ArgumentError, fn -> Feed.envelope("", btc, 1, at, %{}) end

      assert_raise FunctionClauseError, fn ->
        Feed.envelope(Prima.UUID7.generate_id("feed"), btc, -1, at, %{})
      end
    end
  end
end
