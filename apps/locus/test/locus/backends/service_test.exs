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
  body sent only once the messages after it are answered; the MCP route's
  conformance refusals and JSON-RPC codes; and, through the probe
  (`fixtures/probe.mjs`, which needs `node`), a tool call end to end with
  the owner's secrets masked in every answered field.

  Unless a test says otherwise the service's launcher is a stub that
  starts nothing: a backend's process never speaks, but for the stderr a
  vector names, and its release is never reported, so a retiring owner
  stays retiring for the length of a test.
  """

  use ExUnit.Case, async: false

  alias Locus.Backends.{Backend, Owners, Service}
  alias Prima.LocusBackends, as: LB
  alias Prima.MCP.Protocol, as: MCPProtocol

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
  @probe Path.expand("fixtures/probe.mjs", __DIR__)
  @version_key MCPProtocol.meta_protocol_version_key()
  @capabilities_key MCPProtocol.meta_client_capabilities_key()

  defmodule Launcher do
    @moduledoc false
    # Starts nothing: a spawn answers a handle whose process never speaks
    # but for the stderr the test set, and a release is never reported. The
    # pool is the test's.
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

    {launcher_opts, backend_opts} =
      case context[:launcher] do
        :direct ->
          {[launcher: Locus.DirectLauncher, launcher_server: []],
           [release_timeout_ms: 5_000, init_timeout_ms: 30_000]}

        nil ->
          {[launcher: Launcher, launcher_server: launcher], []}
      end

    owners =
      start_supervised!(
        {Owners,
         [
           boot: @boot,
           supervisor: supervisor,
           clock: fn -> Agent.get(clock, & &1) end,
           stop_grace_ms: 100,
           backend_opts: backend_opts
         ] ++ launcher_opts}
      )

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

  defp sync_message(backends, env, opts \\ []) do
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
      backends: backends,
      sealed: sealed
    }
  end

  defp fetch_sync(ctx) do
    backends = [%{name: "fetch", command: "exec cat", env_names: ["API_TOKEN"]}]
    answer = control(ctx, sync_message(backends, %{"fetch" => %{"API_TOKEN" => "sk-canary-0"}}))
    assert answer.status == 200
  end

  # An MCP message, signed with the owner's key.
  defp invoke(ctx, message, opts \\ []) do
    body = if is_binary(message), do: message, else: Jason.encode!(message)
    ts = Agent.get(ctx.now, & &1)
    epoch = Keyword.get(opts, :epoch, @e)
    owner = %{athanor: @athanor, server: @server, generation: @g, epoch: epoch}
    {:ok, owner_key} = LB.owner_key(@key, owner)

    fields =
      Map.merge(owner, %{boot: @boot, ts: ts, nonce: "n_#{System.unique_integer([:positive])}"})

    {:ok, header} = LB.invoke_header(owner_key, fields, Keyword.get(opts, :signed, body))
    headers = [{"x-cyfr-auth", header} | Keyword.get(opts, :headers, mcp_headers(message))]
    post(ctx.port, route("mcp"), body, headers)
  end

  defp mcp(method, params \\ %{}, id \\ 1) do
    meta = %{@version_key => MCPProtocol.version(), @capabilities_key => %{}}

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end

  defp mcp_headers(%{"method" => method} = message) do
    [{"mcp-protocol-version", MCPProtocol.version()}, {"mcp-method", method}] ++
      case message do
        %{"params" => %{"name" => name}} -> [{"mcp-name", name}]
        _ -> []
      end
  end

  defp mcp_headers(_message), do: [{"mcp-protocol-version", MCPProtocol.version()}]

  defp json(%{body: body}), do: Jason.decode!(body)

  defp refusal(code), do: Enum.find(@vectors["refusals"], &(&1["code"] == code))

  defp assert_refused(answer, code) do
    %{"status" => status, "body" => body} = refusal(code)
    assert {answer.status, answer.body} == {status, body}
    assert answer.headers["x-cyfr-boot"] == @boot
  end

  defp wait_until(check, attempts \\ 200) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(25) && wait_until(check, attempts - 1)
    end
  end

  # ————— routes —————

  describe "the routes" do
    test "health answers the protocol version and the release, without a key", ctx do
      answer = post(ctx.port, route("health"), ~s({"version":1}))
      assert answer.status == 200
      assert answer.headers["x-cyfr-boot"] == @boot
      assert json(answer) == %{"version" => 1, "release" => Prima.Version.current()}

      assert_refused(post(ctx.port, route("health"), ~s({"version":2})), "version")
      assert_refused(post(ctx.port, route("health"), ~s({})), "version")
      assert_refused(post(ctx.port, route("health"), ~s({"version":1,"x":1})), "bad_request")
      assert_refused(post(ctx.port, route("health"), "nope"), "bad_request")

      too_large = post(ctx.port, route("health"), String.duplicate(" ", 4097))
      assert_refused(too_large, "too_large")
      assert too_large.headers["connection"] == "close"
    end

    test "a path or method that is no operation is refused, naming the lifetime", ctx do
      assert_refused(post(ctx.port, "/locus/v1/backends/nope", ""), "bad_request")
      assert_refused(post(ctx.port, "/locus/v1/builds/build", ""), "bad_request")
      assert_refused(post(ctx.port, route("control"), "", [], "GET"), "bad_request")

      answer = post(ctx.port, route("mcp"), "", [], "GET")
      assert answer.status == 405
      assert answer.headers["allow"] == "POST"
      assert answer.headers["x-cyfr-boot"] == @boot
      assert %{"error" => %{"code" => -32_600}, "id" => nil} = json(answer)
    end
  end

  # ————— control —————

  describe "control" do
    test "each control type round-trips through the vectors", ctx do
      # A version of another server row at an earlier generation, for the
      # vectors' reconcile to retire.
      other = "mcp_01a09fee-1b2c-7d3e-8f40-5a6b7c8d9e0f"
      backends = [%{name: "fetch", command: "exec cat", env_names: []}]

      seeded =
        control(
          ctx,
          sync_message(backends, %{"fetch" => %{}}, server: other, generation: 2, e: 4),
          generation: 2,
          seq: 1,
          ts: @instant - 1
        )

      assert seeded.status == 200

      for type <- ~w(hello reconcile sync renew release status) do
        v = @vectors[type]
        at(ctx, v["ts"])
        answer = post(ctx.port, route("control"), v["body"], [{"x-cyfr-auth", v["header"]}])
        assert answer.status == 200, "#{type}: #{answer.body}"
        assert answer.headers["x-cyfr-boot"] == @boot
        assert {:ok, read} = LB.read_answer(String.to_existing_atom(type), answer.body), type

        case type do
          # What a live service answers of these is the vectors' own bytes.
          t when t in ~w(hello reconcile sync release) ->
            assert answer.body == v["answer"], type

          "renew" ->
            assert [%{athanor: @athanor, server: @server, e: @e, state: :starting, rev: 0}] =
                     read.renewed

            assert read.unknown == []

          # The release before it retired the owner the status names.
          "status" ->
            assert read.owners == []
        end
      end
    end

    test "every invalid body is refused with the refusal the vectors name", ctx do
      for vector <- @vectors["invalid_messages"] do
        answer = control(ctx, %{}, body: vector["body"])
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
            [{"x-cyfr-auth", @vectors["invoke"]["header"]}],
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
      body = ~s({"version":1,"type":"status","owners":[]})

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
      assert %{"boot" => @boot, "pool" => %{"size" => 64, "free" => 64}} = json(answer)

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
          if message == refused and given["stderr_bytes"], do: await_stderr(ctx, given)
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

  # Every backend's stderr arrived: the status the vector asks for is
  # whole.
  defp await_stderr(ctx, %{"stderr_bytes" => bytes}) do
    wanted = min(bytes, LB.stderr_tail_bytes())

    wait_until(fn ->
      children = DynamicSupervisor.which_children(ctx.supervisor)

      children != [] and
        Enum.all?(children, fn {_, pid, _, _} ->
          byte_size(Backend.status(pid).stderr_tail) >= wanted
        end)
    end)
  end

  # ————— MCP —————

  describe "the MCP route" do
    setup ctx do
      fetch_sync(ctx)
      :ok
    end

    test "discovery answers this revision, stamped with the result type and this service", ctx do
      answer =
        invoke(ctx, mcp("server/discover"),
          headers: [{"x-request-id", "req-1"}] ++ mcp_headers(mcp("server/discover"))
        )

      assert answer.status == 200
      assert answer.headers["mcp-protocol-version"] == MCPProtocol.version()
      assert answer.headers["x-request-id"] == "req-1"
      assert answer.headers["x-cyfr-boot"] == @boot

      assert %{"jsonrpc" => "2.0", "id" => 1, "result" => result} = json(answer)
      assert result["supportedVersions"] == MCPProtocol.supported()
      assert result["resultType"] == "complete"
      assert result["cacheScope"] == "private"
      assert %{"name" => "cyfr-locus"} = result["_meta"][MCPProtocol.meta_server_info_key()]

      # A request without a request id is given one.
      answer = invoke(ctx, mcp("tools/list"))
      assert answer.headers["x-request-id"] =~ ~r/\A[0-9a-f-]{36}\z/
      assert %{"result" => %{"tools" => [], "ttlMs" => 60_000}} = json(answer)
    end

    test "every conformance refusal is a JSON-RPC error at 400", ctx do
      version = MCPProtocol.version()
      call = mcp("tools/call", %{"name" => "fetch__fetch"})
      no_meta = Map.put(mcp("tools/list"), "params", %{})

      without = fn message, key ->
        update_in(message, ["params", "_meta"], &Map.delete(&1, key))
      end

      for {message, headers, code, text} <- [
            {mcp("tools/list"), [{"mcp-method", "tools/list"}], -32_020,
             "Missing required MCP-Protocol-Version"},
            {no_meta, mcp_headers(no_meta), -32_020, "Missing required #{@version_key}"},
            {mcp("tools/list"),
             [{"mcp-protocol-version", "2025-11-25"}, {"mcp-method", "tools/list"}], -32_020,
             "does not match"},
            {put_in(mcp("tools/list"), ["params", "_meta", @version_key], "2025-11-25"),
             [{"mcp-protocol-version", "2025-11-25"}, {"mcp-method", "tools/list"}], -32_022,
             "Unsupported protocol version 2025-11-25"},
            {without.(mcp("tools/list"), @capabilities_key), mcp_headers(mcp("tools/list")),
             -32_602, "Missing required #{@capabilities_key}"},
            {mcp("tools/list"), [{"mcp-protocol-version", version}, {"mcp-method", "tools/call"}],
             -32_020, "Mcp-Method header (tools/call)"},
            {mcp("tools/list"), [{"mcp-protocol-version", version}], -32_020,
             "Mcp-Method header (absent)"},
            {call,
             [
               {"mcp-protocol-version", version},
               {"mcp-method", "tools/call"},
               {"mcp-name", "other"}
             ], -32_020, "Mcp-Name header (other)"},
            {call, [{"mcp-protocol-version", version}, {"mcp-method", "tools/call"}], -32_020,
             "Mcp-Name header (absent)"}
          ] do
        answer = invoke(ctx, message, headers: headers)
        assert answer.status == 400, text
        assert %{"id" => 1, "error" => %{"code" => ^code, "message" => message}} = json(answer)
        assert message =~ text
      end

      # The unsupported revision names the supported one.
      message = put_in(mcp("tools/list"), ["params", "_meta", @version_key], "2025-11-25")
      headers = [{"mcp-protocol-version", "2025-11-25"}, {"mcp-method", "tools/list"}]

      assert %{"error" => %{"data" => %{"supported" => [^version], "requested" => "2025-11-25"}}} =
               json(invoke(ctx, message, headers: headers))

      # A name sent encoded is compared decoded.
      headers = [
        {"mcp-protocol-version", version},
        {"mcp-method", "tools/call"},
        {"mcp-name", "=?base64?#{Base.encode64("fetch__fetch")}?="}
      ]

      assert invoke(ctx, call, headers: headers).status == 200
    end

    test "each JSON-RPC error at its status", ctx do
      assert %{status: 400, body: body} = invoke(ctx, "{nope")
      assert %{"error" => %{"code" => -32_700}, "id" => nil} = Jason.decode!(body)

      assert %{status: 400, body: body} = invoke(ctx, "[]")
      assert %{"error" => %{"code" => -32_600}} = Jason.decode!(body)

      # A notification is answered with nothing.
      notification = Map.delete(mcp("notifications/initialized"), "id")
      assert %{status: 202, body: ""} = invoke(ctx, notification)

      assert %{status: 404} = answer = invoke(ctx, mcp("ping"))

      assert %{"error" => %{"code" => -32_601, "message" => "unsupported method: ping"}} =
               json(answer)

      # A request whose id is null is a request.
      assert %{status: 404} = invoke(ctx, mcp("ping", %{}, nil))

      answer =
        invoke(ctx, mcp("tools/call"),
          headers: [{"mcp-protocol-version", MCPProtocol.version()}, {"mcp-method", "tools/call"}]
        )

      assert answer.status == 200

      assert %{"error" => %{"code" => -32_603, "message" => "tools/call: missing 'name'"}} =
               json(answer)

      for {name, text} <- [
            {"nope", "unknown tool: nope"},
            {"__fetch", "unknown tool: __fetch"},
            {"other__fetch", "unknown tool: other__fetch"},
            {"fetch__fetch", "backend 'fetch' not ready: starting"}
          ] do
        answer = invoke(ctx, mcp("tools/call", %{"name" => name}))
        assert answer.status == 200

        assert %{
                 "result" => %{
                   "isError" => true,
                   "content" => [%{"type" => "text", "text" => ^text}],
                   "resultType" => "complete"
                 }
               } =
                 json(answer)
      end
    end

    test "an unauthorized request is -33001 at 401, and closes the connection unread", ctx do
      message = mcp("tools/list")
      other_key = :binary.copy(<<7>>, 32)

      {:ok, header} =
        LB.invoke_header(
          LB.control_key(other_key),
          %{
            athanor: @athanor,
            server: @server,
            generation: @g,
            epoch: @e,
            boot: @boot,
            ts: @instant,
            nonce: "n_x"
          },
          Jason.encode!(message)
        )

      for headers <- [
            [],
            [{"x-cyfr-auth", header}],
            [{"x-cyfr-auth", @vectors["status"]["header"]}]
          ] do
        answer =
          post(ctx.port, route("mcp"), Jason.encode!(message), headers ++ mcp_headers(message))

        assert answer.status == 401

        assert %{"error" => %{"code" => -33_001, "message" => "unauthorized"}, "id" => nil} =
                 json(answer)

        assert answer.headers["connection"] == "close"
        assert closed?(answer)
      end

      # A body other than the one signed.
      answer = invoke(ctx, message, signed: "{}")
      assert answer.status == 401
      assert %{"error" => %{"code" => -33_001}} = json(answer)
    end

    test "a body past its bound is -32600 at 413, unread", ctx do
      max = LB.max_mcp_bytes()
      owner = %{athanor: @athanor, server: @server, generation: @g, epoch: @e}
      {:ok, owner_key} = LB.owner_key(@key, owner)
      fields = Map.merge(owner, %{boot: @boot, ts: @instant, nonce: "n_big"})
      {:ok, header} = LB.invoke_header(owner_key, fields, "{}")

      socket = connect(ctx.port)
      :ok = :gen_tcp.send(socket, head(route("mcp"), max + 1, [{"x-cyfr-auth", header}]))
      answer = socket |> response("") |> Map.put(:socket, socket)
      assert answer.status == 413

      assert %{"error" => %{"code" => -32_600, "message" => "Request body too large"}} =
               json(answer)

      assert closed?(answer)
    end

    test "a nonce is recorded only once its body was the one signed", ctx do
      message = mcp("tools/list")
      body = Jason.encode!(message)
      owner = %{athanor: @athanor, server: @server, generation: @g, epoch: @e}
      {:ok, owner_key} = LB.owner_key(@key, owner)
      fields = Map.merge(owner, %{boot: @boot, ts: @instant, nonce: "n_once"})
      {:ok, header} = LB.invoke_header(owner_key, fields, body)
      headers = [{"x-cyfr-auth", header} | mcp_headers(message)]

      assert post(ctx.port, route("mcp"), body <> " ", headers).status == 401
      assert post(ctx.port, route("mcp"), body, headers).status == 200
      assert_refused(post(ctx.port, route("mcp"), body, headers), "replay")
    end
  end

  # ————— end to end —————

  describe "a tool call through the probe" do
    @describetag :requires_node
    @describetag launcher: :direct

    test "is answered, and the owner's secrets are masked in every answered field", ctx do
      {node, 0} = System.cmd("node", ["-e", "process.stdout.write(process.execPath)"])
      token = "tok-0123456789abcdef"
      # A value that is also a tool's description, so the catalogue shows it masked.
      description = "Answers its arguments"

      backends = [
        %{
          name: "probe",
          command: ~s(exec "#{node}" "#{@probe}"),
          env_names: ["OTHER", "PROBE_TOKEN"]
        }
      ]

      env = %{"probe" => %{"PROBE_TOKEN" => token, "OTHER" => description}}
      assert control(ctx, sync_message(backends, env)).status == 200

      status = %{type: :status, owners: [%{athanor: @athanor, server: @server}]}

      wait_until(fn ->
        match?(%{"owners" => [%{"state" => "running"}]}, json(control(ctx, status)))
      end)

      tools = json(invoke(ctx, mcp("tools/list")))["result"]["tools"]
      assert Enum.map(tools, & &1["name"]) == ["probe__echo", "probe__secret"]

      assert Enum.find(tools, &(&1["name"] == "probe__echo"))["description"] ==
               "[probe] [REDACTED]"

      answer =
        json(
          invoke(
            ctx,
            mcp("tools/call", %{"name" => "probe__echo", "arguments" => %{"said" => "hi"}})
          )
        )

      assert %{"content" => [%{"text" => ~s({"said":"hi"})}], "resultType" => "complete"} =
               answer["result"]

      answer =
        json(
          invoke(
            ctx,
            mcp("tools/call", %{
              "name" => "probe__secret",
              "arguments" => %{"name" => "PROBE_TOKEN"}
            })
          )
        )

      assert %{"content" => [%{"text" => "[REDACTED]"}]} = answer["result"]

      # The backend's own error, which quotes the caller's text, masked too.
      answer = json(invoke(ctx, mcp("tools/call", %{"name" => "probe__#{token}"})))
      assert %{"isError" => true, "content" => [%{"text" => text}]} = answer["result"]
      refute text =~ token

      # The status's stderr tail, as the backend wrote it, masked.
      wait_until(fn -> control(ctx, status).body =~ "secret PROBE_TOKEN" end)
      body = control(ctx, status).body
      assert body =~ "secret PROBE_TOKEN=[REDACTED]"
      refute body =~ token
      refute body =~ description
    end
  end
end
