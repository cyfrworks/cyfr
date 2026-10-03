# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.WorkerClientTest do
  @moduledoc """
  The worker client signs each request for the worker service it
  addresses, over the body it sends, and answers what that service
  answers. A lost answer is retried once for `kill` and `status` and never
  for `start`; a worker service that cannot be reached, or whose configured
  id no key derives over, is unavailable and nothing is sent. A start the
  service refuses `503` `unavailable` with a refusal's sentence is that
  refusal, carrying the sentence; any other `503` is a lost answer.

  Every request of `tests/fixtures/worker_api.json` is written as the
  vector writes it, and every answer and refusal it lists is read as the
  client's contract says; an answer without the wire's version, at another
  version, or naming `unknown_version`, is a lost answer under the
  callback's retry class.
  """

  use ExUnit.Case, async: false

  alias Crucible.{Keys, WorkerClient}
  alias Prima.{WorkerAPI, WorkerAuth, WorkerWire}

  @service "wrk_client_test"

  @vectors_path Path.expand("../../../../tests/fixtures/worker_api.json", __DIR__)
  @external_resource @vectors_path
  @vectors @vectors_path |> File.read!() |> Jason.decode!()

  # A worker service's listener that verifies each request with the
  # service's dispatch key, tells the test what it saw, and answers what
  # the test scripted for the route: an answer, one with a status, or
  # `:lost` (nothing readable).
  defmodule Stub do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: Map.new(opts)

    @impl true
    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      [header] = get_req_header(conn, WorkerWire.auth_header())
      {:ok, worker_key} = Keys.opus_key(opts.service)
      key = WorkerAuth.dispatch_key(worker_key)
      verified = WorkerAuth.verify_request(key, header, body, System.system_time(:millisecond))
      send(opts.test, {:request, conn.request_path, verified, Jason.decode!(body)})
      send(opts.test, {:body, conn.request_path, body})

      case Map.fetch!(opts.answers, conn.request_path) do
        :lost ->
          send_resp(conn, 200, "")

        {:raw, status, bytes} ->
          conn |> put_resp_content_type("application/json") |> send_resp(status, bytes)

        {status, answer} ->
          json(conn, status, answer)

        answer ->
          json(conn, 200, answer)
      end
    end

    defp json(conn, status, answer) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(answer))
    end
  end

  defp serve!(answers, service \\ @service) do
    pid =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: {Stub, test: self(), service: service, answers: answers},
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false},
          id: {Bandit, System.unique_integer([:positive])}
        )
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    %{id: service, url: "http://127.0.0.1:#{port}", components: nil}
  end

  defp routes(answer),
    do: Map.new(WorkerWire.worker_routes(), fn {_cb, route} -> {route, answer} end)

  test "a request is signed for the service it addresses, over its body, and answers what the service answers" do
    status = %{
      service: @service,
      boot: "boot_1",
      runners: %{fresh: 1, idle: 0, busy: 2, tainted: 1},
      attempts: ["att_1"],
      memory_bytes: 402_653_184,
      refusal: nil
    }

    endpoint =
      serve!(%{
        WorkerWire.worker_route(:start) => WorkerWire.ok(true),
        WorkerWire.worker_route(:kill) => WorkerWire.error(:not_found),
        WorkerWire.worker_route(:status) => WorkerWire.ok(status)
      })

    assert :ok = WorkerClient.start(endpoint, "token", "{}", "sealed")

    assert_receive {:request, "/worker/v1/start",
                    {:ok, %{service: @service, boot: boot, nonce: n1}},
                    %{
                      "op" => "start",
                      "args" => %{
                        "assignment" => "token",
                        "input" => "{}",
                        "sealed_keys" => "sealed"
                      }
                    }}

    assert boot == Prima.Boot.id()

    assert {:error, :not_found} = WorkerClient.kill(endpoint, "exec_1")

    assert_receive {:request, "/worker/v1/kill", {:ok, %{nonce: n2}},
                    %{"op" => "kill", "args" => %{"execution_id" => "exec_1"}}}

    refute n1 == n2

    assert {:ok, ^status} = WorkerClient.status(endpoint)
    assert_receive {:request, "/worker/v1/status", {:ok, _}, %{"op" => "status", "args" => %{}}}
  end

  test "a lost answer is retried once for kill and status, and never for start" do
    endpoint = serve!(routes(:lost))

    assert {:error, :lost} = WorkerClient.kill(endpoint, "exec_1")
    assert_receive {:request, "/worker/v1/kill", {:ok, _}, _}
    assert_receive {:request, "/worker/v1/kill", {:ok, _}, _}
    refute_receive {:request, "/worker/v1/kill", _, _}

    assert {:error, :lost} = WorkerClient.status(endpoint)
    assert_receive {:request, "/worker/v1/status", {:ok, _}, _}
    assert_receive {:request, "/worker/v1/status", {:ok, _}, _}
    refute_receive {:request, "/worker/v1/status", _, _}

    assert {:error, :lost} = WorkerClient.start(endpoint, "token", "{}", "sealed")
    assert_receive {:request, "/worker/v1/start", {:ok, _}, _}
    refute_receive {:request, "/worker/v1/start", _, _}
  end

  test "an answer in another shape, and a status that is not one, are lost" do
    endpoint =
      serve!(%{
        WorkerWire.worker_route(:start) => WorkerWire.ok("started"),
        WorkerWire.worker_route(:kill) => %{"answer" => true},
        WorkerWire.worker_route(:status) => WorkerWire.ok(%{"service" => @service})
      })

    assert {:error, :lost} = WorkerClient.start(endpoint, "token", "{}", "sealed")
    assert {:error, :lost} = WorkerClient.kill(endpoint, "exec_1")
    assert {:error, :lost} = WorkerClient.status(endpoint)
  end

  test "a status is read as the contract requires, a count for every runner state among it" do
    reported = %{
      service: @service,
      boot: "boot_1",
      runners: %{fresh: 1, idle: 0, busy: 2, tainted: 1},
      memory_bytes: nil,
      refusal: nil
    }

    endpoint =
      serve!(%{
        WorkerWire.worker_route(:status) => WorkerWire.ok(Map.put(reported, :attempts, ["att_1"]))
      })

    assert {:ok, %{runners: %{fresh: 1, idle: 0, busy: 2, tainted: 1}, attempts: ["att_1"]}} =
             WorkerClient.status(endpoint)

    # A keeper that refuses runners says so, and the bound it holds them to.
    refusal = %{reason: "memory_unavailable", message: "writable-cgroups=true is missing"}

    endpoint =
      serve!(%{
        WorkerWire.worker_route(:status) =>
          WorkerWire.ok(
            %{reported | memory_bytes: 402_653_184, refusal: refusal}
            |> Map.put(:attempts, [])
          )
      })

    assert {:ok, %{memory_bytes: 402_653_184, refusal: ^refusal}} = WorkerClient.status(endpoint)

    # A status without the bound or the refusal is not one.
    for member <- [:memory_bytes, :refusal] do
      endpoint =
        serve!(%{
          WorkerWire.worker_route(:status) =>
            WorkerWire.ok(reported |> Map.delete(member) |> Map.put(:attempts, []))
        })

      assert {:error, :lost} = WorkerClient.status(endpoint), inspect(member)
    end

    # Every worker service counts its tainted runners; a status without the
    # count is not one.
    for runners <- [
          %{fresh: -1, idle: 0, busy: 0, tainted: 0},
          %{fresh: 0, idle: 0, busy: "2", tainted: 0},
          %{fresh: 0, idle: 0, tainted: 0},
          %{fresh: 1, idle: 0, busy: 2},
          %{fresh: 0, idle: 0, busy: 0, tainted: 0, other: 0}
        ] do
      endpoint =
        serve!(%{
          WorkerWire.worker_route(:status) =>
            WorkerWire.ok(%{reported | runners: runners} |> Map.put(:attempts, []))
        })

      assert {:error, :lost} = WorkerClient.status(endpoint), inspect(runners)
    end
  end

  test "a refusal the service names at 200 is answered as it; any other status is a lost answer" do
    endpoint =
      serve!(%{
        WorkerWire.worker_route(:start) => {200, WorkerWire.error(:malformed)},
        WorkerWire.worker_route(:kill) => {401, WorkerWire.error(:bad_mac)},
        WorkerWire.worker_route(:status) => {404, WorkerWire.error(:not_found)}
      })

    assert {:error, :malformed} = WorkerClient.start(endpoint, "token", "{}", "sealed")
    assert_receive {:request, "/worker/v1/start", _, _}
    refute_receive {:request, "/worker/v1/start", _, _}

    assert {:error, :lost} = WorkerClient.kill(endpoint, "exec_1")
    assert_receive {:request, "/worker/v1/kill", _, _}
    assert_receive {:request, "/worker/v1/kill", _, _}

    assert {:error, :lost} = WorkerClient.status(endpoint)
  end

  test "a start the service refuses 503 with its sentence is its refusal, answered once" do
    sentence =
      "cyfr-keeper cannot bound a runner's memory in this container, so it starts none: " <>
        "start the opus service with the security option writable-cgroups=true"

    endpoint =
      serve!(%{
        WorkerWire.worker_route(:start) =>
          {503, WorkerWire.error(:unavailable, %{"message" => sentence})},
        WorkerWire.worker_route(:kill) =>
          {503, WorkerWire.error(:unavailable, %{"message" => sentence})},
        WorkerWire.worker_route(:status) =>
          {503, WorkerWire.error(:unavailable, %{"message" => sentence})}
      })

    assert {:error, {:unavailable, ^sentence}} =
             WorkerClient.start(endpoint, "token", "{}", "sealed")

    assert_receive {:request, "/worker/v1/start", {:ok, _}, _}
    refute_receive {:request, "/worker/v1/start", _, _}

    # Only a start's refusal names why; any other callback's 503 is lost.
    assert {:error, :lost} = WorkerClient.kill(endpoint, "exec_1")
    assert {:error, :lost} = WorkerClient.status(endpoint)
  end

  test "a start's 503 is a refusal exactly when the contract accepts its sentence" do
    for sentence <- [
          String.duplicate("x", 1024),
          String.duplicate("é", 512),
          String.duplicate("é", 513),
          "tab\there",
          "delete\x7F",
          "a sentence"
        ] do
      endpoint =
        serve!(%{
          WorkerWire.worker_route(:start) =>
            {503, WorkerWire.error(:unavailable, %{"message" => sentence})}
        })

      expected =
        if WorkerAPI.valid_refusal_message?(sentence),
          do: {:error, {:unavailable, sentence}},
          else: {:error, :lost}

      assert WorkerClient.start(endpoint, "token", "{}", "sealed") == expected, inspect(sentence)
    end
  end

  test "a 503 without a refusal's sentence is a lost start" do
    for answer <- [
          {503, WorkerWire.error(:unavailable)},
          {503, WorkerWire.error(:malformed, %{"message" => "a sentence"})},
          {503, WorkerWire.error(:unavailable, %{"message" => ""})},
          {503, WorkerWire.error(:unavailable, %{"message" => "line\nbreak"})},
          {503, WorkerWire.error(:unavailable, %{"message" => String.duplicate("x", 1025)})},
          {503, WorkerWire.error(:unavailable, %{"message" => 42})},
          {502, WorkerWire.error(:unavailable, %{"message" => "a sentence"})},
          :lost
        ] do
      endpoint = serve!(%{WorkerWire.worker_route(:start) => answer})

      assert {:error, :lost} = WorkerClient.start(endpoint, "token", "{}", "sealed"),
             inspect(answer)
    end
  end

  describe "the vectors of tests/fixtures/worker_api.json" do
    test "every request is written as the vector writes it, and its answer read as it says" do
      requests = @vectors["requests"]
      assert Enum.map(requests, & &1["callback"]) == ~w(start kill status)

      for vector <- requests do
        callback = String.to_existing_atom(vector["callback"])
        route = WorkerWire.worker_route(callback)
        %{"v" => 1, "op" => op, "args" => args} = Jason.decode!(vector["body"])
        assert op == vector["callback"]

        answers =
          [{200, vector["answer"]}] ++
            for %{"status" => status, "answer" => answer} <- vector["refusals"],
                do: {status, answer}

        for {status, answer} <- answers do
          endpoint = serve!(%{route => {:raw, status, answer}})
          read = request(endpoint, callback, args)

          # The body the client wrote is the vector's, byte for byte.
          assert_receive {:body, ^route, body}
          assert body == vector["body"], vector["callback"]

          assert read == expected(callback, status, answer, vector),
                 "#{vector["callback"]} at #{status}: #{answer}"

          # A lost answer is asked again once where the callback's class
          # allows it, and never for a start.
          if read == {:error, :lost} and WorkerAPI.retry(callback) == :idempotent do
            assert_receive {:body, ^route, _again}
          end

          refute_receive {:body, ^route, _more}, 50
        end
      end
    end

    test "an answer without the wire's version, at another, or naming unknown_version is lost" do
      sentence = "writable-cgroups=true is missing"

      for answer <- [
            ~s({"ok":true}),
            ~s({"v":2,"ok":true}),
            ~s({"v":"1","ok":true}),
            ~s({"v":1,"ok":true,"extra":1}),
            ~s({"error":"not_found"}),
            ~s({"v":2,"error":"not_found"}),
            ~s({"v":1,"error":"unknown_version"})
          ] do
        endpoint = serve!(routes({:raw, 200, answer}))

        assert {:error, :lost} = WorkerClient.kill(endpoint, "exec_1"), answer
        assert_receive {:body, "/worker/v1/kill", _}
        assert_receive {:body, "/worker/v1/kill", _}

        assert {:error, :lost} = WorkerClient.status(endpoint), answer
        assert_receive {:body, "/worker/v1/status", _}
        assert_receive {:body, "/worker/v1/status", _}

        assert {:error, :lost} = WorkerClient.start(endpoint, "token", "{}", "sealed"), answer
        assert_receive {:body, "/worker/v1/start", _}
        refute_receive {:body, "/worker/v1/start", _}, 50
      end

      # A start's refusal is one only at this version.
      for answer <- [
            Jason.encode!(%{"error" => "unavailable", "message" => sentence}),
            Jason.encode!(%{"v" => 2, "error" => "unavailable", "message" => sentence})
          ] do
        endpoint = serve!(%{WorkerWire.worker_route(:start) => {:raw, 503, answer}})
        assert {:error, :lost} = WorkerClient.start(endpoint, "token", "{}", "sealed"), answer
      end
    end
  end

  # The request of `callback` the vector's args make, as the client's own
  # function makes it.
  defp request(endpoint, :start, args),
    do: WorkerClient.start(endpoint, args["assignment"], args["input"], args["sealed_keys"])

  defp request(endpoint, :kill, %{"execution_id" => id}), do: WorkerClient.kill(endpoint, id)
  defp request(endpoint, :status, %{}), do: WorkerClient.status(endpoint)

  # What the client answers for `answer` at `status`, as its contract reads
  # it: a `200` is the callback's answer or its refusal by name (a worker
  # service at another version, `unknown_version`, is lost); a start's `503`
  # naming a refusal's sentence is that refusal; anything else is lost.
  defp expected(callback, 200, answer, vector) do
    case WorkerWire.read_answer(Jason.decode!(answer)) do
      {:ok, true} when callback in [:start, :kill] ->
        :ok

      {:ok, status} when callback == :status ->
        assert answer == vector["answer"]
        WorkerAPI.read_status(status)

      {:error, "unknown_version", _fields} ->
        {:error, :lost}

      {:error, name, _fields} ->
        {:error, String.to_existing_atom(name)}
    end
  end

  defp expected(:start, 503, answer, _vector) do
    case WorkerWire.read_answer(Jason.decode!(answer)) do
      {:error, "unavailable", %{"message" => sentence}} ->
        if WorkerAPI.valid_refusal_message?(sentence),
          do: {:error, {:unavailable, sentence}},
          else: {:error, :lost}

      _other ->
        {:error, :lost}
    end
  end

  defp expected(_callback, _status, _answer, _vector), do: {:error, :lost}

  test "a worker service that cannot be reached is unavailable" do
    endpoint = %{id: @service, url: "http://127.0.0.1:19", components: nil}

    assert {:error, :unavailable} = WorkerClient.status(endpoint)
    assert {:error, :unavailable} = WorkerClient.kill(endpoint, "exec_1")
    assert {:error, :unavailable} = WorkerClient.start(endpoint, "token", "{}", "sealed")
  end

  test "a configured id no key derives over is unavailable, and nothing is sent" do
    endpoint = %{serve!(routes(WorkerWire.ok(true))) | id: "wrk bad id"}

    assert {:error, :unavailable} = WorkerClient.status(endpoint)
    assert {:error, :unavailable} = WorkerClient.kill(endpoint, "exec_1")
    refute_receive {:request, _, _, _}
  end
end
