# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.FeedTest do
  @moduledoc """
  Feeds against `tests/fixtures/feed.json`: every valid binding reads and
  writes back to itself, every refused binding is refused at its path for
  its reason, the inputs, crons, results and envelopes are the fixture's,
  the fixture's rows at the byte bounds are their stated bytes and are
  accepted or refused as it says, the size before the shape, and a binding
  id has its grammar. Beside them, the envelope's refusal to carry
  anything but the binding's display part, and the terms JSON cannot spell
  (an improper list, a key that is not a string, a struct), a struct
  missing a field, and the shared readers handed a term outside their
  arguments, which are refused, or raise, without the value they carry.
  """

  use ExUnit.Case, async: true

  alias Prima.Feed
  alias Prima.Feed.{Action, Binding, Read}

  @vectors Path.expand("../../../../tests/fixtures/feed.json", __DIR__)

  # A value no refusal may carry.
  @canary "c4n4ry-feed-0a6c"

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp json_bytes(value) do
    {:ok, text} = Prima.Json.encode(value)
    byte_size(text)
  end

  defp run_action(args),
    do: %{"name" => "go", "label" => "Go", "kind" => "run", "operation" => "go", "args" => args}

  # The report of the ArgumentError `fun` raises, its stacktrace included;
  # any other exception, or none, fails the test.
  defp raised(fun) do
    fun.()
    flunk("expected an ArgumentError")
  rescue
    e in ArgumentError -> Exception.format(:error, e, __STACKTRACE__)
  end

  # What `fun` answers, or the report of the ArgumentError it raises, its
  # stacktrace included; any other exception fails the test.
  defp outcome(fun) do
    {:answered, fun.()}
  rescue
    e in ArgumentError -> {:raised, Exception.format(:error, e, __STACKTRACE__)}
  end

  # Whether `text` carries the canary, as its bytes or as the byte list
  # `inspect/1` prints for a binary that is not UTF-8 text.
  defp carries_canary?(text) do
    String.contains?(text, [@canary, @canary |> :binary.bin_to_list() |> Enum.join(", ")])
  end

  # A refusal is text, its path and its reason, and carries no canary. The
  # path is read itself, not through `inspect/1`, which would print a
  # binary that is not UTF-8 text as a byte list.
  defp value_free!({:error, %{path: path, reason: reason}} = refusal) do
    assert String.valid?(path) and String.valid?(reason), inspect(refusal)
    refute carries_canary?(path), inspect(refusal)
  end

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
      assert_raise ArgumentError, fn -> Feed.input(refresh) end
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

    test "every result row at the byte bound is its stated bytes, the size checked before the shape" do
      %{"binding" => index, "results" => %{"valid" => valid, "invalid" => invalid}} =
        vectors()["bounds"]

      binding = Enum.at(bindings(), index)
      assert valid != [] and invalid != []

      for %{"why" => why, "bytes" => bytes, "result" => result} <- valid do
        assert json_bytes(result) == bytes, why
        assert bytes == Feed.result_max_bytes(), why
        assert Feed.check_result(binding, result) == :ok, why
      end

      for %{"why" => why, "bytes" => bytes, "result" => result, "path" => path} = row <- invalid do
        assert json_bytes(result) == bytes, why
        assert bytes == Feed.result_max_bytes() + 1, why

        assert Feed.check_result(binding, result) ==
                 {:error, %{path: path, reason: row["reason"]}},
               why

        # The shape alone: what the size refusal takes precedence over.
        case row do
          %{"shape_refusal" => %{"path" => at, "reason" => reason}} ->
            assert Prima.Canvas.Shape.check(binding.result_shape, result) ==
                     {:error, %{path: at, reason: reason}},
                   why

          _within_shape ->
            assert Prima.Canvas.Shape.check(binding.result_shape, result) == :ok, why
        end
      end

      assert Enum.any?(invalid, &Map.has_key?(&1, "shape_refusal"))
    end

    test "every args row at the byte bound is its stated bytes, refused at /args past it" do
      %{"binding" => index, "args" => %{"valid" => valid, "invalid" => invalid}} =
        vectors()["bounds"]

      json = Enum.at(vectors()["bindings"]["valid"], index)["binding"]
      assert valid != [] and invalid != []

      for %{"why" => why, "bytes" => bytes, "args" => args} <- valid do
        assert json_bytes(args) == bytes, why
        assert bytes == Feed.args_max_bytes(), why
        assert {:ok, %Binding{args: ^args}} = Binding.validate(%{json | "args" => args}), why

        run = run_action(args)
        assert {:ok, %Action{args: ^args}} = Action.validate(run), why
      end

      for %{"why" => why, "bytes" => bytes, "args" => args, "path" => path} = row <- invalid do
        assert json_bytes(args) == bytes, why
        assert bytes == Feed.args_max_bytes() + 1, why

        assert Binding.validate(%{json | "args" => args}) ==
                 {:error, %{path: path, reason: row["reason"]}},
               why

        run = run_action(args)

        assert Binding.validate(%{json | "actions" => [run]}) ==
                 {:error, %{path: "/actions/0" <> path, reason: row["reason"]}},
               why
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

    test "args may hold floats and nulls, and only JSON" do
      [btc | _] = vectors()["bindings"]["valid"] |> Enum.map(& &1["binding"])

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

      assert_raise ArgumentError, fn ->
        Feed.envelope(Prima.UUID7.generate_id("feed"), btc, -1, at, %{})
      end
    end
  end

  describe "refusals name no value they were handed" do
    setup do
      [json | _] = vectors()["bindings"]["valid"] |> Enum.map(& &1["binding"])
      {:ok, btc} = Binding.validate(json)
      %{json: json, btc: btc}
    end

    test "a key that is not a string in a binding, an action, its args or its shape",
         %{json: json} do
      [refresh | _] = json["actions"]

      # A binary that is not UTF-8 text is no string either: no pointer
      # spells it.
      keys = [
        {:key, @canary},
        [@canary],
        %{@canary => 1},
        String.to_atom(@canary),
        <<0xFF>> <> @canary,
        @canary <> <<0xC3>>
      ]

      for key <- keys do
        cases = [
          {Map.put(json, key, @canary), %{path: "", reason: "unknown_key"}},
          {%{json | "actions" => [Map.put(refresh, key, @canary)]},
           %{path: "/actions/0", reason: "unknown_key"}},
          {%{json | "args" => %{key => @canary}}, %{path: "/args", reason: "json"}},
          {%{json | "result_shape" => Map.put(json["result_shape"], key, @canary)},
           %{path: "/result_shape", reason: "unknown_key"}},
          {%{
             json
             | "result_shape" => %{"type" => "object", "fields" => %{key => %{"type" => "json"}}}
           }, %{path: "/result_shape/fields", reason: "name"}}
        ]

        for {binding, expected} <- cases do
          refusal = Binding.validate(binding)
          assert refusal == {:error, expected}, inspect(key)
          value_free!(refusal)
        end

        refusal = Action.validate(Map.put(refresh, key, @canary))
        assert refusal == {:error, %{path: "", reason: "unknown_key"}}
        value_free!(refusal)
      end
    end

    test "an improper list or a struct in a binding, its actions, its args or a result",
         %{json: json, btc: btc} do
      [refresh | _] = json["actions"]
      struct = %URI{path: @canary}

      cases = [
        {%{json | "actions" => [refresh | @canary]}, %{path: "/actions", reason: "type"}},
        {%{json | "actions" => [@canary | :bad_tail]}, %{path: "/actions", reason: "type"}},
        {%{json | "actions" => [struct]}, %{path: "/actions/0", reason: "type"}},
        {%{json | "args" => %{"xs" => [1 | @canary]}}, %{path: "/args", reason: "json"}},
        {%{json | "args" => struct}, %{path: "/args", reason: "type"}},
        {%{json | "result_shape" => %{"type" => "enum", "values" => ["a" | @canary]}},
         %{path: "/result_shape/values", reason: "type"}},
        {struct, %{path: "", reason: "type"}}
      ]

      for {binding, expected} <- cases do
        refusal = Binding.validate(binding)
        assert refusal == {:error, expected}
        value_free!(refusal)
      end

      for result <- [
            [@canary | :bad_tail],
            %{"candles" => [1 | @canary]},
            %{{:key, @canary} => 1},
            %{(<<0xFF>> <> @canary) => 1},
            struct
          ] do
        refusal = Feed.check_result(btc, result)
        assert refusal == {:error, %{path: "", reason: "json"}}
        value_free!(refusal)
      end
    end

    test "a builder handed a term outside its arguments raises without it", %{btc: btc} do
      at = ~U[2026-10-04 12:00:00Z]
      id = Prima.UUID7.generate_id("feed")
      secret = %{btc | args: %{"key" => @canary}}
      [refresh | _] = btc.actions

      calls = [
        fn -> Feed.input(%{"operation" => @canary}) end,
        fn -> Feed.input(%{refresh | label: @canary}) end,
        fn -> Feed.cron(%{secret | interval_minutes: 7}) end,
        fn -> Feed.cron({@canary}) end,
        fn -> Feed.check_result(%{"result_shape" => @canary}, %{"price" => @canary}) end,
        fn -> Feed.check_result(%{btc | result_shape: {@canary}}, %{"price" => 1}) end,
        fn -> Feed.envelope(@canary, btc, 1, at, %{}) end,
        fn -> Feed.envelope(id, secret, -1, at, %{"price" => @canary}) end,
        fn -> Feed.envelope(id, secret, 1, @canary, %{"price" => @canary}) end,
        fn -> Feed.envelope(id, %{secret | actions: [@canary]}, 1, at, %{}) end,
        fn -> Feed.envelope(id, %{secret | actions: [refresh | @canary]}, 1, at, %{}) end,
        fn -> Feed.envelope(id, secret, 1, %{at | year: @canary}, %{}) end,
        fn -> Feed.envelope(id, secret, 1, %{at | month: 13, zone_abbr: @canary}, %{}) end,
        fn -> Binding.to_json(%{"name" => @canary}) end,
        fn -> Binding.to_json(%{secret | actions: [@canary]}) end,
        fn -> Binding.to_json(%{secret | actions: [refresh | @canary]}) end,
        fn -> Action.to_json(%{"name" => @canary}) end,
        fn -> Action.to_json(%{refresh | kind: @canary}) end
      ]

      for call <- calls do
        refute carries_canary?(raised(call))
      end
    end

    test "the shared readers raise without a term outside their arguments", %{btc: btc} do
      terms = [
        {@canary},
        [@canary | :bad_tail],
        %URI{path: @canary},
        Map.delete(%{btc | args: %{"key" => @canary}}, :name)
      ]

      # Each reader's arguments, one position at a time replaced by each
      # term: the decoded value, the grammar's terms and the pointer.
      readers = [
        {&Read.known_keys/3, [%{"name" => 1}, ["name"], ""]},
        {&Read.fetch/3, [%{"name" => 1}, "name", ""]},
        {&Read.name/2, ["btc", "/name"]},
        {&Read.label/3, ["Bitcoin", 80, "/label"]},
        {&Read.operation/2, ["quote", "/operation"]},
        {&Read.args/2, [%{}, "/args"]},
        {&Read.json_text/3, [%{}, 4096, "/args"]},
        {&Read.refuse/2, ["/args", "size"]},
        {&Read.proper_length/1, [[1]]}
      ]

      for {reader, args} <- readers,
          position <- 0..(length(args) - 1),
          term <- terms do
        case outcome(fn -> apply(reader, List.replace_at(args, position, term)) end) do
          {:raised, report} -> refute carries_canary?(report), inspect(reader)
          {:answered, {:error, _refusal} = refusal} -> value_free!(refusal)
          {:answered, _value} -> :ok
        end
      end
    end
  end

  describe "a struct missing a field its function reads raises without the canary" do
    setup do
      [json | _] = vectors()["bindings"]["valid"] |> Enum.map(& &1["binding"])
      {:ok, %Binding{actions: [refresh, run]} = btc} = Binding.validate(json)

      # The canary sits in more than one field of each struct, so it is
      # still there whichever one field is removed.
      refresh = %{refresh | name: @canary, label: @canary}
      run = %{run | name: @canary, label: @canary, operation: @canary, args: %{"key" => @canary}}

      secret = %{
        btc
        | name: @canary,
          label: @canary,
          reference: "catalyst:local." <> @canary,
          operation: @canary,
          args: %{"key" => @canary},
          actions: [refresh, run]
      }

      %{
        secret: secret,
        refresh: refresh,
        run: run,
        id: Prima.UUID7.generate_id("feed"),
        at: ~U[2026-10-04 12:00:00Z]
      }
    end

    # The three cases of the delta check: each raised a KeyError whose
    # report printed the struct.
    test "Binding.to_json/1 of a binding without its name", %{secret: secret} do
      refute carries_canary?(raised(fn -> Binding.to_json(Map.delete(secret, :name)) end))
    end

    test "Action.to_json/1 of a run action without its operation", %{run: run} do
      refute carries_canary?(raised(fn -> Action.to_json(Map.delete(run, :operation)) end))
    end

    test "envelope/5 of a binding without its label", %{secret: secret, id: id, at: at} do
      binding = Map.delete(secret, :label)
      refute carries_canary?(raised(fn -> Feed.envelope(id, binding, 1, at, %{}) end))
    end

    test "every function, each field removed in turn",
         %{secret: secret, refresh: refresh, run: run, id: id, at: at} do
      every_binding_field = secret |> Map.from_struct() |> Map.keys()

      # Each function with the binding fields it reads: removing one of them
      # raises, removing any other either answers or raises, never with the
      # canary.
      binding_calls = [
        {"Binding.to_json/1", &Binding.to_json/1, every_binding_field},
        {"Feed.envelope/5", &Feed.envelope(id, &1, 1, at, %{}), [:name, :label, :actions]},
        {"Feed.input/1", &Feed.input/1, [:operation, :args]},
        {"Feed.cron/1", &Feed.cron/1, [:interval_minutes]},
        {"Feed.check_result/2", &Feed.check_result(&1, %{"price" => 1}), [:result_shape]}
      ]

      for field <- every_binding_field, {name, call, read} <- binding_calls do
        held_to_its_reads(name, field, read, fn -> call.(Map.delete(secret, field)) end)
      end

      every_action_field = run |> Map.from_struct() |> Map.keys()
      refresh_reads = [:name, :label, :kind]

      action_calls = [
        {"Action.to_json/1 of a refresh", refresh, &Action.to_json/1, refresh_reads},
        {"Action.to_json/1 of a run", run, &Action.to_json/1, every_action_field},
        {"Feed.input/1 of a run", run, &Feed.input/1, [:kind, :operation, :args]},
        {"Binding.to_json/1 of a refresh", refresh, &Binding.to_json(%{secret | actions: [&1]}),
         refresh_reads},
        {"Binding.to_json/1 of a run", run, &Binding.to_json(%{secret | actions: [&1]}),
         every_action_field},
        {"Feed.envelope/5 of an action", run,
         &Feed.envelope(id, %{secret | actions: [&1]}, 1, at, %{}), [:name, :label]}
      ]

      for field <- every_action_field, {name, action, call, read} <- action_calls do
        held_to_its_reads(name, field, read, fn -> call.(Map.delete(action, field)) end)
      end
    end
  end

  # Removing a field `name`'s call reads raises an ArgumentError; removing
  # any other may answer. Neither the raise nor a refusal carries the
  # canary.
  defp held_to_its_reads(name, field, read, fun) do
    case outcome(fun) do
      {:raised, report} ->
        refute carries_canary?(report), "#{name} without #{field}"

      {:answered, answer} ->
        refute field in read, "#{name} without #{field} answered"
        with {:error, _refusal} <- answer, do: value_free!(answer)
    end
  end
end
