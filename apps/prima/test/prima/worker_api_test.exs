# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.WorkerAPITest do
  @moduledoc """
  Every WorkerAPI request of `tests/fixtures/worker_api.json` reproduces
  from its fields under the dispatch key the vector keys derive: its
  header over its plain body verifies under that key as a request, never
  as a report, and its body reads as its callback at this version. Its
  answer and every refusal read as the answer they are; a `503` refusal
  of a start is one only when it names a sentence a status refusal may
  carry.
  """

  use ExUnit.Case, async: true

  alias Prima.{WorkerAPI, WorkerAuth, WorkerWire}

  @vectors Path.expand("../../../../tests/fixtures/worker_api.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()
  @keys Path.expand("../../../../tests/fixtures/worker_auth.json", __DIR__)
        |> File.read!()
        |> Jason.decode!()

  @fields ~w(service boot ts nonce)a

  defp dispatch_key do
    root = Base.decode16!(@keys["root_hex"], case: :lower)
    {:ok, worker_key} = WorkerAuth.worker_key(root, @keys["service"])
    key = WorkerAuth.dispatch_key(worker_key)
    assert Base.encode16(key, case: :lower) == @keys["keys"]["dispatch_hex"]
    key
  end

  test "the vectors name every callback's route, retry class and timeout" do
    names = Enum.map(WorkerAPI.callbacks(), &Atom.to_string/1)

    for section <- ~w(routes retries timeouts_ms),
        do: assert(Enum.sort(Map.keys(@vectors[section])) == Enum.sort(names))

    for callback <- WorkerAPI.callbacks(), name = Atom.to_string(callback) do
      assert @vectors["routes"][name] == WorkerWire.worker_route(callback)
      assert @vectors["retries"][name] == Atom.to_string(WorkerAPI.retry(callback))
      assert @vectors["timeouts_ms"][name] == WorkerAPI.request_timeout_ms(callback)
    end

    assert @vectors["version"] == WorkerWire.version()
  end

  test "every request reproduces, verifies as a request only and reads as its callback" do
    key = dispatch_key()
    root = Base.decode16!(@keys["root_hex"], case: :lower)

    assert Enum.sort(Enum.map(@vectors["requests"], & &1["callback"])) ==
             Enum.sort(Enum.map(WorkerAPI.callbacks(), &Atom.to_string/1))

    for %{"callback" => callback, "body" => body, "header" => header} = request <-
          @vectors["requests"] do
      fields = Map.new(@fields, &{&1, Map.fetch!(request["fields"], Atom.to_string(&1))})

      assert {:ok, header} == WorkerAuth.request_header(key, fields, body)
      assert {:ok, ^fields} = WorkerAuth.verify_request(key, header, body, fields.ts)
      assert {:ok, ^fields, hash} = WorkerAuth.verify_request_header(key, header, fields.ts)
      assert :ok = WorkerAuth.verify_body(hash, body)
      assert {:error, :malformed} = WorkerAuth.verify_report(root, header, body, fields.ts)

      assert {:error, :unknown_version} =
               WorkerAuth.verify_request(
                 key,
                 String.replace_prefix(header, "v1 ", "v2 "),
                 body,
                 fields.ts
               )

      assert {:ok, read, _args} = WorkerWire.read_request_body(WorkerAPI, Jason.decode!(body))
      assert Atom.to_string(read) == callback
    end
  end

  test "every answer and refusal reads as what it is" do
    for %{"callback" => callback, "answer" => answer, "refusals" => refusals} <-
          @vectors["requests"] do
      assert {:ok, value} = WorkerWire.read_answer(Jason.decode!(answer))

      case callback do
        "status" -> assert {:ok, _status} = WorkerAPI.read_status(value)
        _start_or_kill -> assert value == true
      end

      for %{"status" => status, "answer" => refused, "why" => why} <- refusals do
        assert {:error, name, fields} = WorkerWire.read_answer(Jason.decode!(refused)), why
        assert status in [200, 401, 503], why

        # A 503 is the worker service's refusal of a start only with a
        # sentence; without one it is a lost answer.
        if status == 503 do
          assert callback == "start" and name == "unavailable", why

          assert WorkerAPI.valid_refusal_message?(fields["message"]) ==
                   Map.has_key?(fields, "message"),
                 why
        end
      end
    end
  end
end
