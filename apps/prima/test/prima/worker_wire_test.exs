# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.WorkerWireTest do
  @moduledoc """
  The wire's shape as data: every callback of both behaviours has one
  route and no two callbacks share one; a route reads back to its
  callback; a request body and an answer carry the version first, a body
  at no version or another is refused before its op is read and an
  answer at none is lost; a request body names its callback and reads
  back only as a callback of the behaviour it is read for; answers spell
  success and refusal one way. A runner's exit report at its bound fits
  the body bound when every identifier in it is the longest the protocol
  carries, escaped at every byte, and one attempt more does not. Every
  body and answer of
  `tests/fixtures/host_api.json` and `tests/fixtures/worker_api.json`
  reads and writes back to its bytes.
  """

  use ExUnit.Case, async: true

  alias Prima.{HostAPI, RunnerControl, WorkerAPI, WorkerWire}

  test "the auth header is one lowercase HTTP header name" do
    assert WorkerWire.auth_header() == "x-cyfr-auth"
    assert WorkerWire.auth_header() == String.downcase(WorkerWire.auth_header())
  end

  test "every host callback has one route under /host/v1, and reports go there too" do
    routes = WorkerWire.host_routes()

    assert Enum.sort(Map.keys(routes)) == Enum.sort(HostAPI.callbacks())
    assert Enum.uniq(Map.values(routes)) == Map.values(routes)

    for callback <- HostAPI.callbacks() do
      route = WorkerWire.host_route(callback)
      assert route == "/host/v1/#{callback}"
      assert {:ok, ^callback} = WorkerWire.host_callback(route)
    end

    assert WorkerWire.host_route(:runner_exited) == "/host/v1/runner_exited"
    assert :error = WorkerWire.host_callback("/host/v1/nope")
    assert :error = WorkerWire.host_callback("/worker/v1/kill")
    assert_raise FunctionClauseError, fn -> WorkerWire.host_route(:kill) end
  end

  test "every worker callback has one route under /worker/v1" do
    routes = WorkerWire.worker_routes()

    assert Enum.sort(Map.keys(routes)) == Enum.sort(WorkerAPI.callbacks())
    assert Enum.uniq(Map.values(routes)) == Map.values(routes)

    for callback <- WorkerAPI.callbacks() do
      route = WorkerWire.worker_route(callback)
      assert route == "/worker/v1/#{callback}"
      assert {:ok, ^callback} = WorkerWire.worker_callback(route)
    end

    assert :error = WorkerWire.worker_callback("/host/v1/attach")
    assert_raise FunctionClauseError, fn -> WorkerWire.worker_route(:attach) end
  end

  test "a request body carries the version first, names its callback and reads back for its behaviour only" do
    body = WorkerWire.request_body(:admit_child, %{"reference" => "r"})
    assert Jason.encode!(body) == ~s({"v":3,"op":"admit_child","args":{"reference":"r"}})
    assert WorkerWire.version() == 3

    decoded = body |> Jason.encode!() |> Jason.decode!()
    assert decoded == %{"v" => 3, "op" => "admit_child", "args" => %{"reference" => "r"}}

    assert {:ok, :admit_child, %{"reference" => "r"}} =
             WorkerWire.read_request_body(HostAPI, decoded)

    assert {:error, :malformed} = WorkerWire.read_request_body(WorkerAPI, decoded)

    assert {:ok, :kill, %{}} =
             WorkerWire.read_request_body(WorkerAPI, %{"v" => 3, "op" => "kill", "args" => %{}})

    for malformed <- [
          %{"v" => 3, "op" => "nope", "args" => %{}},
          %{"v" => 3, "op" => "attach", "args" => []},
          %{"v" => 3, "op" => "attach"},
          %{"v" => 3, "args" => %{}},
          %{"v" => 3, "op" => :attach, "args" => %{}},
          %{"v" => 3, "op" => "attach", "args" => %{}, "extra" => true},
          "attach",
          ["attach"],
          nil
        ] do
      assert {:error, :malformed} = WorkerWire.read_request_body(HostAPI, malformed),
             Prima.LoggerContext.shape(malformed)
    end
  end

  test "a body at no version or another is refused before its op is read" do
    for body <- [
          %{"op" => "attach", "args" => %{}},
          %{"v" => 4, "op" => "attach", "args" => %{}},
          %{"v" => 0, "op" => "nope"},
          %{"v" => "2", "op" => "attach", "args" => %{}},
          %{"v" => 3.0, "op" => "attach", "args" => %{}},
          %{"v" => nil},
          %{}
        ] do
      assert {:error, :unknown_version} = WorkerWire.read_request_body(HostAPI, body)
      assert {:error, :unknown_version} = WorkerWire.read_request_body(WorkerAPI, body)
    end
  end

  test "answers carry the version first and spell success as ok and a refusal by name with its fields" do
    assert Jason.encode!(WorkerWire.ok(true)) == ~s({"v":3,"ok":true})
    assert Jason.encode!(WorkerWire.ok(%{"a" => 1})) == ~s({"v":3,"ok":{"a":1}})
    assert Jason.encode!(WorkerWire.error(:lost)) == ~s({"v":3,"error":"lost"})

    assert Jason.encode!(WorkerWire.error(:guest_error, %{"type" => "denied", "message" => "no"})) ==
             ~s({"v":3,"error":"guest_error","message":"no","type":"denied"})

    assert Jason.encode!(WorkerWire.error("failed", %{"message" => "m"})) ==
             ~s({"v":3,"error":"failed","message":"m"})

    assert Jason.encode!(WorkerWire.error("failed", %{"error" => "other", "v" => 4})) ==
             ~s({"v":3,"error":"failed"})
  end

  test "an answer reads back to what it says, and anything else is a lost answer" do
    round_trip = &(&1 |> Jason.encode!() |> Jason.decode!() |> WorkerWire.read_answer())

    assert {:ok, true} = round_trip.(WorkerWire.ok(true))
    assert {:ok, nil} = round_trip.(WorkerWire.ok(nil))
    assert {:ok, %{"a" => 1}} = round_trip.(WorkerWire.ok(%{"a" => 1}))
    assert {:error, "lost", %{}} = round_trip.(WorkerWire.error(:lost))

    assert {:error, "guest_error", %{"type" => "denied", "message" => "no"}} =
             round_trip.(WorkerWire.error(:guest_error, %{"type" => "denied", "message" => "no"}))

    for lost <- [
          %{"ok" => true},
          %{"error" => "lost"},
          %{"v" => 4, "ok" => true},
          %{"v" => "2", "ok" => true},
          %{"v" => 3},
          %{"v" => 3, "ok" => true, "extra" => 1},
          %{"v" => 3, "ok" => true, "error" => "lost"},
          %{"v" => 3, "error" => :lost},
          %{"v" => 3, "error" => nil},
          [1, true],
          "ok",
          nil
        ] do
      assert :lost = WorkerWire.read_answer(lost), Prima.LoggerContext.shape(lost)
    end
  end

  describe "the message vectors" do
    @host Path.expand("../../../../tests/fixtures/host_api.json", __DIR__)
          |> File.read!()
          |> Jason.decode!()
    @worker Path.expand("../../../../tests/fixtures/worker_api.json", __DIR__)
            |> File.read!()
            |> Jason.decode!()

    defp writes_back(behaviour, body) do
      assert {:ok, callback, args} = WorkerWire.read_request_body(behaviour, Jason.decode!(body))
      assert Jason.encode!(WorkerWire.request_body(callback, args)) == body
      callback
    end

    defp answers_back(answer) do
      case WorkerWire.read_answer(Jason.decode!(answer)) do
        {:ok, value} ->
          assert Jason.encode!(WorkerWire.ok(value)) == answer
          {:ok, value}

        {:error, name, fields} ->
          assert Jason.encode!(WorkerWire.error(name, fields)) == answer
          {:error, name}
      end
    end

    test "every request body reads as its callback or is refused, the version first" do
      assert length(@worker["request_bodies"]) >= 20

      for c <- @worker["request_bodies"] do
        expected =
          if c["error"],
            do: {:error, String.to_existing_atom(c["error"])},
            else: {:ok, String.to_existing_atom(c["callback"]), c["args"]}

        assert WorkerWire.read_request_body(WorkerAPI, Jason.decode!(c["body"])) == expected,
               c["why"]
      end
    end

    test "every answer reads as ok, a refusal with its fields, or a lost answer" do
      for c <- @worker["answers"] do
        expected =
          case c["reading"] do
            "ok" -> {:ok, c["ok"]}
            "error" -> {:error, c["error"], c["fields"]}
            "lost" -> :lost
          end

        assert WorkerWire.read_answer(Jason.decode!(c["answer"])) == expected, c["why"]
      end
    end

    test "every answer and body written is its bytes" do
      for c <- @worker["answer_writes"] do
        written =
          case c["write"] do
            "ok" -> WorkerWire.ok(c["ok"])
            "error" -> WorkerWire.error(c["error"], c["fields"])
            "request" -> WorkerWire.request_body(String.to_existing_atom(c["op"]), c["args"])
          end

        assert Jason.encode!(written) == c["bytes"], c["why"]
      end
    end

    test "every base URL reads as its base, or is no base URL" do
      for %{"text" => text, "base" => base} <- @worker["base_urls"] do
        expected = if base, do: {:ok, base}, else: :error
        assert WorkerWire.base_url(text) == expected, inspect(text)
      end
    end

    test "a report names at most the vectors' count of attempts" do
      assert WorkerWire.max_report_attempts() == @worker["max_report_attempts"]
    end

    test "the vectors are at this version, named on the header this wire uses" do
      assert @host["version"] == WorkerWire.version()
      assert @worker["version"] == WorkerWire.version()
      assert @host["auth_header"] == WorkerWire.auth_header()

      assert @host["routes"] ==
               Map.new(WorkerWire.host_routes(), fn {cb, route} -> {Atom.to_string(cb), route} end)

      assert @worker["routes"] ==
               Map.new(WorkerWire.worker_routes(), fn {cb, route} ->
                 {Atom.to_string(cb), route}
               end)
    end

    test "every call's and pin case's body and answer read and write back to their bytes" do
      calls =
        @host["calls"] ++ @host["egress_pin_cases"] ++ @host["egress_pin_internal_purposes"]

      assert calls != []

      for %{"callback" => callback, "body" => body} = call <- calls do
        assert Atom.to_string(writes_back(HostAPI, body)) == callback

        # An attached request's success is its frames: it has no one answer.
        case call do
          %{"answer" => answer} -> assert {_ok_or_error, _value} = answers_back(answer)
          %{"callback" => "attached_fetch"} -> :ok
        end

        for %{"answer" => refused} <- Map.get(call, "refusals", []) do
          assert {:error, _name} = answers_back(refused), callback
        end
      end

      assert Enum.any?(calls, &(&1["callback"] == "attached_fetch"))

      assert writes_back(HostAPI, @host["report"]["body"]) == :runner_exited
      assert writes_back(HostAPI, @host["report"]["cross_member"]["body"]) == :runner_exited
      assert {:ok, true} = answers_back(@host["report"]["answer"])
    end

    test "every request's body and answer read and write back to their bytes" do
      assert @worker["requests"] != []

      for %{"callback" => callback, "body" => body, "answer" => answer, "refusals" => refusals} <-
            @worker["requests"] do
        assert Atom.to_string(writes_back(WorkerAPI, body)) == callback
        assert {:ok, _value} = answers_back(answer)
        assert {:error, _} = WorkerWire.read_request_body(HostAPI, Jason.decode!(body))

        for %{"answer" => refused} <- refusals do
          assert {:error, _name} = answers_back(refused), callback
        end
      end
    end

    test "every opened body a listener refuses is refused with its error, at the renew route" do
      refusals = @host["body_refusals"]

      assert Enum.sort(Enum.map(refusals, & &1["error"]) |> Enum.uniq()) ==
               ["malformed", "unknown_version"]

      for %{"name" => name, "body" => body, "error" => error} <- refusals do
        refused =
          case WorkerWire.read_request_body(HostAPI, Jason.decode!(body)) do
            {:ok, :renew, _args} -> flunk("#{name} reads as the renew route's own call")
            {:ok, _other_callback, _args} -> "malformed"
            {:error, reason} -> Atom.to_string(reason)
          end

        assert refused == error, name
      end
    end

    test "an answer without its version is a lost answer, whatever it says" do
      for %{"answer" => answer} <- @host["calls"] ++ @worker["requests"] do
        unversioned = answer |> Jason.decode!() |> Map.delete("v")
        assert :lost = WorkerWire.read_answer(unversioned)
        assert :lost = WorkerWire.read_answer(Map.put(unversioned, "v", 4))
      end
    end
  end

  describe "a runner's exit report" do
    # `n` distinct identifiers, each the longest the worker protocol
    # carries and every byte of it one JSON escapes to two.
    defp worst_ids(n) do
      for i <- 1..n//1 do
        bits =
          i
          |> Integer.to_string(2)
          |> String.pad_leading(12, "0")
          |> String.replace("0", "\"")
          |> String.replace("1", "\\")

        String.duplicate("\\", 256 - byte_size(bits)) <> bits
      end
    end

    # The report of `n` attempts, its member and runner at the worst too,
    # as a worker service encodes it.
    defp report(n) do
      [member, runner | attempts] = worst_ids(n + 2)

      Jason.encode!(
        WorkerWire.request_body(:runner_exited, %{
          "member" => member,
          "runner" => runner,
          "attempts" => attempts
        })
      )
    end

    test "the worst identifier is the longest the protocol carries, and escapes to twice its bytes" do
      [id] = worst_ids(1)
      assert byte_size(id) == 256
      assert byte_size(Jason.encode!(id)) == 2 * 256 + 2

      # A runner's frame carries it, and one byte more is refused both
      # ways.
      frame = %{type: :child, execution_id: "exec_1", attempt: id}
      line = frame |> RunnerControl.encode() |> IO.iodata_to_binary()
      assert {:ok, ^frame} = RunnerControl.decode(line)

      longer = "\\" <> id
      assert_raise ArgumentError, fn -> RunnerControl.encode(%{frame | attempt: longer}) end

      assert {:error, _reason} =
               line
               |> String.replace(Jason.encode!(id), Jason.encode!(longer))
               |> RunnerControl.decode()
    end

    test "names at most as many attempts as fit the body bound at their worst: 2 033" do
      max = WorkerWire.max_report_attempts()
      assert max == 2_033

      at_bound = report(max)
      assert byte_size(at_bound) <= HostAPI.max_body_bytes()
      assert byte_size(report(max + 1)) > HostAPI.max_body_bytes()

      assert {:ok, :runner_exited, %{"attempts" => attempts}} =
               WorkerWire.read_request_body(HostAPI, Jason.decode!(at_bound))

      assert length(attempts) == max
      assert length(Enum.uniq(attempts)) == max
    end
  end

  test "a base URL is http or https with a host and nothing after it" do
    assert {:ok, "http://127.0.0.1:4200"} = WorkerWire.base_url("http://127.0.0.1:4200")

    assert {:ok, "https://locus.internal"} =
             WorkerWire.base_url("https://locus.internal/")

    assert {:ok, "http://[::1]:4300"} = WorkerWire.base_url("http://[::1]:4300")

    for bad <- [
          "locus:4200",
          "ftp://locus:4200",
          "http://",
          "http:///worker",
          "http://locus:4200/worker/v1",
          "http://locus:4200?x=1",
          "http://locus:4200#f",
          "http://user:pw@locus:4200",
          "",
          nil,
          4200
        ] do
      assert :error = WorkerWire.base_url(bad), "#{inspect(bad)} is no base URL"
    end
  end
end
