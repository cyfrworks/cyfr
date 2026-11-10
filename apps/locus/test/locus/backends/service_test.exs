# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.ServiceTest do
  @moduledoc """
  The backends service over a loopback port, met with the shared vectors
  (`tests/fixtures/locus_backends.json`) at their own instant and boot:
  every route and the lifetime every answer names; each control type's
  round trip through the vectors; every invalid body refused with its
  refusal; header-first refusals that close the connection with the body
  unread; the body bounds and the hash check; every fence vector
  (`fence_rejected`) replayed against a fresh service, a held message's
  body sent only once the messages after it are answered; the session
  route's round trips through the vectors, its refusals before and after
  the body, and, through the test environment's `Locus.DirectLauncher`, a
  session end to end: lines sent and received, the owner's secrets masked
  in every line, a recv replayed by its `after`, a close.

  Unless a test says otherwise the service's launcher is a stub that
  starts nothing: a session's process never speaks, but for the stderr a
  vector names, and its release is never reported, so a retiring owner
  stays retiring for the length of a test.
  """

  use ExUnit.Case, async: false

  import Prima.Test.Wait

  alias Locus.Backends.{Backend, Owners, Service}
  alias Prima.LocusBackends, as: LB

  @vectors Path.expand("../../../../../tests/fixtures/locus_backends.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  @key Base.decode16!(@vectors["key_hex"], case: :lower)
  @boot @vectors["sync"]["fields"]["boot"]
  @cyfr_boot @vectors["sync"]["fields"]["cyfr_boot"]
  @athanor @vectors["owner"]["athanor"]
  @server @vectors["owner"]["server"]
  @g @vectors["owner"]["generation"]
  @e @vectors["owner"]["epoch"]
  @instant @vectors["hello"]["ts"]
  # The budget the vectors' hello names, room for every session a vector
  # opens.
  @roomy_budget Jason.decode!(@vectors["hello"]["answer"])["memory"]["budget_bytes"]

  defmodule Launcher do
    @moduledoc false
    # Starts nothing: a spawn answers a handle whose process never speaks
    # but for the stderr the test set, and a release is never reported. The
    # pool is the test's; a kept home is made, empty, and reset or retired
    # at once.
    import Kernel, except: [send: 2]

    def pool_stats(agent, "backends") do
      case Agent.get(agent, & &1.pool) do
        "unavailable" -> {:error, {:launcher_unavailable, :timeout}}
        pool -> {:ok, %{size: pool["size"], free: pool["free"], quarantined: pool["quarantined"]}}
      end
    end

    def spawn(agent, _spec) do
      ref = make_ref()

      case Agent.get(agent, & &1.stderr_bytes) do
        0 -> :ok
        bytes -> Kernel.send(self(), {__MODULE__, ref, {:stderr, :binary.copy("x", bytes)}})
      end

      {:ok, %{ref: ref, spawn_id: nil, uid: nil, pid: nil}}
    end

    def send(_handle, _data), do: :ok
    def signal(_handle, _sig), do: :ok
    def release(_agent, _handle, _grace_ms), do: :ok
    def home_ensure(_agent, _id), do: {:ok, 40_001}
    def home_measure(_agent, _id), do: {:ok, 0}
    def home_reset(_agent, _id), do: :ok
    def home_retire(_agent, _id), do: :ok

    # The homes the vectors' `homes` answer names, in another order: the
    # service answers them sorted.
    def home_list(_agent),
      do:
        {:ok,
         ["vlt_01a09fee-3d4e-7f50-9b6c-7d8e9f0a1b2c", "vlt_01a09fee-2c3d-7e4f-8a5b-6c7d8e9f0a1b"]}
  end

  setup context do
    :ets.delete_all_objects(Service.Nonces)
    given = Map.get(context, :given, %{})

    launcher =
      start_supervised!(
        {Agent,
         fn ->
           %{
             pool: given["pool"] || %{"size" => 64, "free" => 64, "quarantined" => 0},
             stderr_bytes: given["stderr_bytes"] || 0
           }
         end},
        id: :launcher
      )

    clock = start_supervised!({Agent, fn -> 1_000_000 end}, id: :clock)
    now = start_supervised!({Agent, fn -> @instant end}, id: :now)
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: :backends)

    {launcher_opts, session_opts} =
      case context[:launcher] do
        :direct ->
          {[launcher: Locus.DirectLauncher, launcher_server: []], [release_timeout_ms: 5_000]}

        nil ->
          {[launcher: Launcher, launcher_server: launcher], []}
      end

    owners =
      start_supervised!({Owners,
       [
         boot: @boot,
         supervisor: supervisor,
         clock: fn -> Agent.get(clock, & &1) end,
         stop_grace_ms: 100,
         session_opts: session_opts,
         # Room for every session a vector opens, but where it names
         # the budget it tests.
         memory_budget: given["memory_budget"] || @roomy_budget,
         overcommit: {1, 1}
       ] ++ launcher_opts})

    server =
      start_supervised!(
        Locus.Backends.listener(
          plug: {Service, owners: owners, key: @key, now: fn -> Agent.get(now, & &1) end},
          ip: {127, 0, 0, 1},
          port: 0,
          startup_log: false
        )
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, port: port, clock: clock, now: now, supervisor: supervisor, owners: owners}
  end

  # ————— the client —————

  defp route(name), do: @vectors["routes"][name]

  defp connect(port) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 5_000)

    socket
  end

  defp head(path, length, headers, method \\ "POST") do
    [
      "#{method} #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: #{length}\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n"
    ]
  end

  # Posts `body` and reads the whole answer: `%{status, headers, body, socket}`,
  # the socket still open for a test that asks whether the service closed it.
  defp post(port, path, body, headers \\ [], method \\ "POST") do
    socket = connect(port)
    :ok = :gen_tcp.send(socket, [head(path, byte_size(body), headers, method), body])
    socket |> response("") |> Map.put(:socket, socket)
  end

  defp response(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        [status_line | lines] = String.split(head, "\r\n")
        [_version, code | _reason] = String.split(status_line, " ")

        headers =
          Map.new(lines, fn line ->
            [name, value] = String.split(line, ":", parts: 2)
            {String.downcase(name), String.trim(value)}
          end)

        case String.to_integer(code) do
          100 ->
            response(socket, rest)

          status ->
            length = String.to_integer(headers["content-length"] || "0")
            %{status: status, headers: headers, body: exactly(socket, rest, length)}
        end

      [_partial] ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 30_000)
        response(socket, buffer <> more)
    end
  end

  defp exactly(_socket, buffer, length) when byte_size(buffer) >= length,
    do: binary_part(buffer, 0, length)

  defp exactly(socket, buffer, length) do
    {:ok, more} = :gen_tcp.recv(socket, 0, 30_000)
    exactly(socket, buffer <> more, length)
  end

  # Whether the service closed the connection once it answered.
  defp closed?(%{socket: socket}) do
    closed = :gen_tcp.recv(socket, 0, 5_000) == {:error, :closed}
    :gen_tcp.close(socket)
    closed
  end

  defp at(%{now: now}, ts), do: Agent.update(now, fn _ -> ts end)

  defp seq, do: System.unique_integer([:positive, :monotonic]) + 1_000

  # A control message signed as CYFR signs one.
  defp control(ctx, message, opts \\ []) do
    body =
      Keyword.get_lazy(opts, :body, fn ->
        {:ok, body} = LB.encode_control(message)
        body
      end)

    ts = Keyword.get(opts, :ts, Agent.get(ctx.now, & &1))

    fields = %{
      generation: Keyword.get(opts, :generation, @g),
      seq: Keyword.get_lazy(opts, :seq, &seq/0),
      cyfr_boot: @cyfr_boot,
      boot: Keyword.get(opts, :boot, if(message[:type] == :hello, do: "-", else: @boot)),
      ts: ts
    }

    {:ok, header} = LB.control_header(LB.control_key(@key), fields, body)
    post(ctx.port, route("control"), body, [{"x-cyfr-auth", header}])
  end

  defp sync_message(programs, env, opts \\ []) do
    owner = %{athanor: @athanor, server: Keyword.get(opts, :server, @server)}
    e = Keyword.get(opts, :e, @e)

    {:ok, sealed} =
      LB.seal(
        LB.seal_key(@key),
        Map.merge(owner, %{generation: Keyword.get(opts, :generation, @g), epoch: e}),
        @boot,
        Jason.encode!(env)
      )

    %{
      type: :sync,
      owner: owner,
      e: e,
      lease_ms: 30_000,
      idle_ms: 600_000,
      programs: programs,
      sealed: sealed
    }
  end

  defp program(name, command),
    do: %{
      name: name,
      command: command,
      login_command: nil,
      env_names: ["API_TOKEN"],
      home: :scratch,
      memory_bytes: nil,
      home_max_bytes: nil
    }

  @canary "sk-canary-0123456789"

  defp fetch_sync(ctx, command \\ "exec cat") do
    answer =
      control(
        ctx,
        sync_message([program("fetch", command)], %{"fetch" => %{"API_TOKEN" => @canary}})
      )

    assert answer.status == 200
  end

  # A session message, signed with the owner's key.
  defp invoke(ctx, message, opts \\ []) do
    body =
      cond do
        is_binary(message) ->
          message

        true ->
          {:ok, body} =
            message
            |> Map.merge(%{owner: %{athanor: @athanor, server: @server}, e: @e})
            |> LB.encode_session()

          body
      end

    ts = Agent.get(ctx.now, & &1)
    epoch = Keyword.get(opts, :epoch, @e)
    owner = %{athanor: @athanor, server: @server, generation: @g, epoch: epoch}
    {:ok, owner_key} = LB.owner_key(@key, owner)

    fields =
      Map.merge(owner, %{boot: @boot, ts: ts, nonce: "n_#{System.unique_integer([:positive])}"})

    {:ok, header} = LB.invoke_header(owner_key, fields, Keyword.get(opts, :signed, body))
    post(ctx.port, route("session"), body, [{"x-cyfr-auth", header}])
  end

  defp open_message(opts \\ []) do
    %{
      type: :open,
      program: "fetch",
      home_id: nil,
      key: Keyword.get(opts, :key, "mcp"),
      mode: :run,
      argv: Keyword.get(opts, :argv, [])
    }
  end

  defp json(%{body: body}), do: Jason.decode!(body)

  defp refusal(code), do: Enum.find(@vectors["refusals"], &(&1["code"] == code))

  defp assert_refused(answer, code) do
    %{"status" => status, "body" => body} = refusal(code)
    assert {answer.status, answer.body} == {status, body}
    assert answer.headers["x-cyfr-boot"] == @boot
  end

  # ————— routes —————

  describe "the routes" do
    test "health answers the protocol version and the release, without a key", ctx do
      answer = post(ctx.port, route("health"), LB.health_body())
      assert answer.status == 200
      assert answer.headers["x-cyfr-boot"] == @boot
      assert json(answer) == %{"version" => 2, "release" => Prima.Version.current()}

      assert_refused(post(ctx.port, route("health"), ~s({"version":1})), "version")
      assert_refused(post(ctx.port, route("health"), ~s({})), "version")
      assert_refused(post(ctx.port, route("health"), ~s({"version":2,"x":1})), "bad_request")
      assert_refused(post(ctx.port, route("health"), "nope"), "bad_request")

      too_large = post(ctx.port, route("health"), String.duplicate(" ", 4097))
      assert_refused(too_large, "too_large")
      assert too_large.headers["connection"] == "close"
    end

    test "a path or method that is no operation is refused, naming the lifetime", ctx do
      assert_refused(post(ctx.port, "/locus/v1/backends/nope", ""), "bad_request")
      assert_refused(post(ctx.port, "/locus/v1/builds/build", ""), "bad_request")
      assert_refused(post(ctx.port, route("control"), "", [], "GET"), "bad_request")
      assert_refused(post(ctx.port, route("session"), "", [], "GET"), "bad_request")
      assert_refused(post(ctx.port, "/locus/v1/backends/mcp", "{}"), "bad_request")
    end
  end

  # ————— control —————

  describe "control" do
    test "each control type round-trips through the vectors", ctx do
      # A version of another server row at an earlier generation, for the
      # vectors' reconcile to retire.
      other = "mcp_01a09fee-1b2c-7d3e-8f40-5a6b7c8d9e0f"
      programs = [%{program("fetch", "exec cat") | env_names: []}]

      seeded =
        control(
          ctx,
          sync_message(programs, %{"fetch" => %{}}, server: other, generation: 2, e: 4),
          generation: 2,
          seq: 1,
          ts: @instant - 1
        )

      assert seeded.status == 200

      for type <- ~w(hello reconcile sync renew release status home homes) do
        v = @vectors[type]
        at(ctx, v["ts"])
        answer = post(ctx.port, route("control"), v["body"], [{"x-cyfr-auth", v["header"]}])
        assert answer.status == 200, "#{type}: #{answer.body}"
        assert answer.headers["x-cyfr-boot"] == @boot
        assert {:ok, read} = LB.read_answer(String.to_existing_atom(type), answer.body), type

        case type do
          # What a live service answers of these is the vectors' own bytes.
          t when t in ~w(hello reconcile sync release home homes) ->
            assert answer.body == v["answer"], type

          "renew" ->
            assert [%{athanor: @athanor, server: @server, e: @e, state: :running}] =
                     read.renewed

            assert read.unknown == []

          # The release before it retired the owner the status names.
          "status" ->
            assert read.owners == []
        end
      end
    end

    test "every invalid body is refused with the refusal the vectors name, on its route", ctx do
      fetch_sync(ctx)

      for vector <- @vectors["invalid_messages"] do
        answer =
          case Jason.decode(vector["body"]) do
            {:ok, %{"type" => type}} when type in ~w(open send recv close) ->
              invoke(ctx, vector["body"])

            _ ->
              control(ctx, %{}, body: vector["body"])
          end

        assert_refused(answer, vector["refusal"])
      end
    end

    test "the header is verified before the body is read, and a refusal closes the connection",
         ctx do
      v = @vectors["status"]
      at(ctx, v["ts"])
      builds_header = Locus.Test.Wire.header(v["body"])
      [_, mac] = String.split(v["header"], " mac=")
      tampered = String.replace(v["header"], mac, String.reverse(mac))

      for headers <- [
            [],
            [{"x-cyfr-auth", builds_header}],
            [{"x-cyfr-auth", tampered}],
            [{"x-cyfr-auth", @vectors["open"]["header"]}],
            [{"x-cyfr-auth", v["header"]}, {"x-cyfr-auth", v["header"]}]
          ] do
        answer = post(ctx.port, route("control"), v["body"], headers)
        assert_refused(answer, "unauthorized")
        assert answer.headers["connection"] == "close"
        assert closed?(answer)
      end

      # Outside the window of this clock.
      at(ctx, v["ts"] + LB.window_ms() + 1)
      answer = post(ctx.port, route("control"), v["body"], [{"x-cyfr-auth", v["header"]}])
      assert_refused(answer, "unauthorized")
    end

    test "a body past its bound is refused unread, one not the one signed is unauthorized", ctx do
      max = LB.max_control_bytes()
      body = ~s({"version":2,"type":"status","owners":[]})

      fields = %{generation: @g, seq: seq(), cyfr_boot: @cyfr_boot, boot: @boot, ts: @instant}
      {:ok, header} = LB.control_header(LB.control_key(@key), fields, body)

      # Declared past the bound: nothing of it is read.
      socket = connect(ctx.port)
      :ok = :gen_tcp.send(socket, head(route("control"), max + 1, [{"x-cyfr-auth", header}]))
      answer = socket |> response("") |> Map.put(:socket, socket)
      assert_refused(answer, "too_large")
      assert closed?(answer)

      # Another body than the one the header hashed.
      answer = post(ctx.port, route("control"), body <> " ", [{"x-cyfr-auth", header}])
      assert_refused(answer, "unauthorized")

      # The first message at a sequence is applied; its header again is stale.
      answer = post(ctx.port, route("control"), body, [{"x-cyfr-auth", header}])
      assert answer.status == 200

      assert_refused(
        post(ctx.port, route("control"), body, [{"x-cyfr-auth", header}]),
        "stale_control"
      )
    end

    test "a hello names no lifetime, and answers this one", ctx do
      answer = control(ctx, %{type: :hello, g: @g, cyfr_boot: @cyfr_boot})
      assert answer.status == 200

      assert %{
               "boot" => @boot,
               "pool" => %{"size" => 64, "free" => 64},
               "memory" => %{
                 "budget_bytes" => @roomy_budget,
                 "admission_limit_bytes" => @roomy_budget,
                 "held_bytes" => 0
               }
             } = json(answer)

      # A hello whose members are not its header's is no hello.
      assert_refused(
        control(ctx, %{type: :hello, g: @g + 1, cyfr_boot: @cyfr_boot}),
        "bad_request"
      )

      assert_refused(control(ctx, %{type: :hello, g: @g, cyfr_boot: "boot_other"}), "bad_request")
    end
  end

  # ————— the fences —————

  describe "the fence vectors" do
    for vector <- @vectors["fence_rejected"] do
      @tag given: Map.get(vector, "given", %{})
      @tag fence: vector
      test "#{vector["name"]} is refused #{vector["refusal"]}", ctx do
        fence(ctx, ctx.fence)
      end
    end

    test "cover every fence the service keeps" do
      covered = @vectors["fence_rejected"] |> Enum.map(& &1["refusal"]) |> Enum.uniq()

      for code <- ~w(stale_boot stale_control stale_epoch epoch_ahead conflict lapsed
                     unknown_owner replay capacity unavailable too_many_owners
                     status_too_large nonce_cache_full),
          do: assert(code in covered, code)
    end
  end

  defp fence(ctx, %{"name" => name, "sequence" => sequence, "refusal" => code} = vector) do
    given = Map.get(vector, "given", %{})

    if held = given["nonces_held"], do: hold_nonces(held)

    messages = Enum.filter(sequence, &Map.has_key?(&1, "route"))
    refused = Enum.find(messages, & &1["hold"]) || List.last(messages)

    {held, answers} =
      Enum.reduce(sequence, {nil, %{}}, fn
        %{"advance_ms" => ms}, acc ->
          Agent.update(ctx.clock, &(&1 + ms))
          acc

        %{"hold" => true} = message, {nil, answers} ->
          at(ctx, message["now"])
          {hold(ctx.port, message), answers}

        message, {held, answers} ->
          at(ctx, message["now"])
          if message == refused and given["stderr_bytes"], do: await_stderr(ctx, messages, given)
          {held, Map.put(answers, message, send_message(ctx.port, message))}
      end)

    answers = if held, do: Map.put(answers, refused, release(held)), else: answers

    for message <- messages, message != refused do
      assert answers[message].status == message["status"], "#{name}: #{answers[message].body}"
    end

    answer = answers[refused]
    assert_refused(answer, code)

    if refused["read_body"] == false,
      do: assert(answer.headers["connection"] == "close", name)
  end

  defp send_message(port, message),
    do: post(port, route(message["route"]), message["body"], headers(message))

  defp headers(message),
    do: [{"x-cyfr-auth", message["header"]} | Map.to_list(Map.get(message, "headers", %{}))]

  # The head sent with `expect: 100-continue`: the service's asking for the
  # body is the event that says the checks before the body passed.
  defp hold(port, message) do
    socket = connect(port)

    headers = [{"expect", "100-continue"} | headers(message)]

    :ok =
      :gen_tcp.send(socket, head(route(message["route"]), byte_size(message["body"]), headers))

    continued(socket, "")
    {socket, message}
  end

  defp continued(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      assert buffer =~ ~r/\AHTTP\/1\.1 100 Continue\r\n/
    else
      {:ok, more} = :gen_tcp.recv(socket, 0, 30_000)
      continued(socket, buffer <> more)
    end
  end

  defp release({socket, message}) do
    :ok = :gen_tcp.send(socket, message["body"])
    socket |> response("") |> Map.put(:socket, socket)
  end

  defp hold_nonces(count) do
    rows =
      for i <- 1..count,
          do: {{@athanor, @server, @g, @e, "held_#{i}"}, System.system_time(:millisecond) * 2}

    true = :ets.insert(Service.Nonces, rows)
  end

  # Every session the vector's opens started has its stderr: the status
  # the vector asks for is whole.
  defp await_stderr(ctx, messages, %{"stderr_bytes" => bytes}) do
    wanted = min(bytes, LB.stderr_tail_bytes())
    named = Enum.count(messages, &(&1["route"] == "session"))

    wait_until(
      fn ->
        children = DynamicSupervisor.which_children(ctx.supervisor)

        length(children) == named and
          Enum.all?(children, fn {_, pid, _, _} ->
            byte_size(Backend.status(pid, 5_000).stderr_tail) >= wanted
          end)
      end,
      5_000
    )
  end

  # ————— sessions —————

  describe "the session route" do
    test "each session message reads and verifies as the vectors say", ctx do
      fetch_sync(ctx)

      # The vectors' open, at its instant: a session of its own, answered
      # in the open answer's shape.
      v = @vectors["open"]
      at(ctx, v["fields"]["ts"])
      answer = post(ctx.port, route("session"), v["body"], [{"x-cyfr-auth", v["header"]}])
      assert answer.status == 200, answer.body

      assert {:ok, %{status: :running, resumed: false, pty: false}} =
               LB.read_session_answer(:open, answer.body)

      # The vectors' send, recv and close name a session this service never
      # opened: read and verified, they are refused as unknown.
      for type <- ~w(send recv close) do
        v = @vectors[type]
        at(ctx, v["fields"]["ts"])
        answer = post(ctx.port, route("session"), v["body"], [{"x-cyfr-auth", v["header"]}])
        assert_refused(answer, "unknown_session")
      end
    end

    @tag launcher: :direct
    test "a session end to end: lines sent and received, masked, replayed, closed", ctx do
      fetch_sync(ctx, ~s(echo "token $API_TOKEN"; exec cat))

      opened = invoke(ctx, open_message())
      assert opened.status == 200, opened.body

      assert {:ok, %{session: session, resumed: false}} =
               LB.read_session_answer(:open, opened.body)

      again = invoke(ctx, open_message())

      assert {:ok, %{session: ^session, resumed: true}} =
               LB.read_session_answer(:open, again.body)

      sent = invoke(ctx, %{type: :send, session: session, lines: ["hello", "again"]})
      assert {:ok, %{status: :running}} = LB.read_session_answer(:send, sent.body)

      recv = fn after_seq ->
        answer =
          invoke(ctx, %{type: :recv, session: session, after: after_seq, max_wait_ms: 2_000})

        assert answer.status == 200, answer.body
        {:ok, read} = LB.read_session_answer(:recv, answer.body)
        read
      end

      wait_until(fn -> length(recv.(0).lines) == 3 end, 10_000)
      read = recv.(0)
      assert Enum.map(read.lines, & &1.text) == ["token [REDACTED]", "hello", "again"]
      refute inspect(read) =~ @canary
      assert %{running: true, dropped: 0} = read

      # Replayed by the same after, the same lines; past them, none.
      assert Enum.map(recv.(1).lines, & &1.text) == ["hello", "again"]
      assert Enum.map(recv.(1).lines, & &1.text) == ["hello", "again"]

      past =
        invoke(ctx, %{type: :recv, session: session, after: 3, max_wait_ms: 0})

      assert {:ok, %{lines: []}} = LB.read_session_answer(:recv, past.body)

      closed = invoke(ctx, %{type: :close, session: session})
      assert {:ok, %{status: :closed}} = LB.read_session_answer(:close, closed.body)
      assert %{running: false} = recv.(3)

      sent = invoke(ctx, %{type: :send, session: session, lines: ["late"]})
      assert {:ok, %{status: :ended}} = LB.read_session_answer(:send, sent.body)
    end

    test "a session message is refused before its body for its owner, and after it for its shape",
         ctx do
      fetch_sync(ctx)

      # No owner at that epoch: refused with the body unread.
      answer = invoke(ctx, open_message(), epoch: @e + 1)
      assert_refused(answer, "epoch_ahead")
      assert answer.headers["connection"] == "close"

      # A body other than the one signed.
      {:ok, body} =
        open_message()
        |> Map.merge(%{owner: %{athanor: @athanor, server: @server}, e: @e})
        |> LB.encode_session()

      assert_refused(invoke(ctx, body <> " ", signed: body), "unauthorized")

      # A body naming another owner than its signature.
      {:ok, other} =
        open_message()
        |> Map.merge(%{owner: %{athanor: @athanor, server: "mcp_other"}, e: @e})
        |> LB.encode_session()

      assert_refused(invoke(ctx, other), "bad_request")

      # A control body on the session route, and a program the owner lacks.
      assert_refused(invoke(ctx, @vectors["status"]["body"]), "bad_request")
      assert_refused(invoke(ctx, %{open_message() | program: "nope"}), "unknown_program")

      unknown = "ss_" <> String.duplicate("9", 32)
      assert_refused(invoke(ctx, %{type: :close, session: unknown}), "unknown_session")
    end

    test "a session body past its bound is refused unread", ctx do
      fetch_sync(ctx)
      max = LB.max_session_bytes()
      owner = %{athanor: @athanor, server: @server, generation: @g, epoch: @e}
      {:ok, owner_key} = LB.owner_key(@key, owner)
      fields = Map.merge(owner, %{boot: @boot, ts: @instant, nonce: "n_big"})
      {:ok, header} = LB.invoke_header(owner_key, fields, "{}")

      socket = connect(ctx.port)
      :ok = :gen_tcp.send(socket, head(route("session"), max + 1, [{"x-cyfr-auth", header}]))
      answer = socket |> response("") |> Map.put(:socket, socket)
      assert_refused(answer, "too_large")
      assert closed?(answer)
    end
  end
end
