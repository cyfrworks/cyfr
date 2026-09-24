# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuilderServiceTest do
  @moduledoc """
  The builds service over its wire, as a client meets it: a real listener
  on a loopback port, requests signed as CYFR signs them, answers read line
  by line (`Locus.Test.Wire`).

  Before its stream a build is refused at its class's status with nothing
  spawned: a header that does not verify (before any of the body is read),
  a replayed nonce, a body past the bound or other than the one signed, a
  route that is none, another version, a deadline already passed, a missing
  toolchain, a cap reached. After it, the answer is lines: a result, or the
  refusal the build ended with, its diagnostics bounded. A deadline reached
  mid-build ends the build's process group; a client that leaves ends its
  build within a bound and its slot goes back; the spawner's memory answers
  are the wire's `memory` and `unavailable`.
  """

  # Serves on the application's build slots and, in places, as its spawner.
  use ExUnit.Case, async: false

  alias Prima.{BuilderProtocol, Slots}
  alias Locus.Test.{FakeKeeper, Wire}

  @slots Locus.BuildSlots
  @build BuilderProtocol.route(:build)
  @health BuilderProtocol.route(:health)

  setup do
    {:ok, port: Wire.serve!()}
  end

  defp wait_until(check, attempts \\ 200) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(50) && wait_until(check, attempts - 1)
    end
  end

  defp refused(port, request_or_body, opts \\ []) do
    assert {status, [{:refusal, refusal, diagnostics}]} = answer(port, request_or_body, opts)
    assert status == BuilderProtocol.status(refusal)
    {refusal, diagnostics}
  end

  defp answer(port, %{} = request, opts), do: Wire.build(port, request, opts)

  defp answer(port, body, opts) when is_binary(body),
    do: Wire.post(port, @build, body, [{"x-cyfr-auth", Wire.header(body, opts)}])

  defp alive?(os_pid) do
    {_out, status} = System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true)
    status == 0
  end

  # A build script that says where it runs: it writes its shell's pid and
  # the pid of a child it started to `file`, one a line, prints `running`
  # and waits on the child for longer than any test.
  defp lingering do
    file = Path.join(System.tmp_dir!(), "locus_svc_#{System.unique_integer([:positive])}.pids")
    on_exit(fn -> File.rm(file) end)
    {"sleep 300 & echo $$ > #{file}; echo $! >> #{file}; echo running >&2; wait", file}
  end

  defp pids_in(file) do
    wait_until(fn ->
      match?({:ok, text} when byte_size(text) > 0, File.read(file)) and
        length(String.split(File.read!(file), "\n", trim: true)) == 2
    end)

    String.split(File.read!(file), "\n", trim: true)
  end

  # The application's spawner for the test: `Locus.Keeper` under its own
  # name, which is how the service finds it, against a fake cyfr-keeper.
  defp spawner!(mode) do
    {fake, channel} = FakeKeeper.start()
    :ok = FakeKeeper.mode(fake, mode)
    attach_dir = FakeKeeper.short_tmp_dir()
    client = start_supervised!({Locus.Keeper, channel: channel, attach_dir: attach_dir})
    :ok = :socket.setopt(channel, {:otp, :controlling_process}, client)

    on_exit(fn ->
      Process.exit(fake, :kill)
      File.rm_rf!(attach_dir)
    end)

    fake
  end

  defp spawns(fake), do: Enum.filter(FakeKeeper.requests(fake), &(&1["type"] == "spawn"))

  describe "health" do
    test "answers without a key: the release and every language's toolchain", %{port: port} do
      assert {200, [{:health, health}]} =
               Wire.post(port, @health, BuilderProtocol.encode_health_request())

      assert health.release == BuilderProtocol.release()
      assert health.toolchains == Locus.Builder.available_toolchains()
    end

    test "refuses another version, a field it does not have and a body past its bound", %{
      port: port
    } do
      assert {409, [{:refusal, {:protocol_mismatch, 1, 2}, []}]} =
               Wire.post(port, @health, ~s({"version":2}))

      assert {400, [{:refusal, {:malformed, sentence}, []}]} =
               Wire.post(port, @health, ~s({"version":1,"verbose":true}))

      assert sentence =~ "verbose"

      assert {400, [{:refusal, {:malformed, sentence}, []}]} =
               Wire.post(port, @health, String.duplicate(" ", 5_000) <> ~s({"version":1}))

      assert sentence =~ "at most 4096"
    end
  end

  describe "what is no operation of the service" do
    test "is refused malformed: another path, another method, the routes of the wire before this one",
         %{port: port} do
      for {method, path} <- [
            {"POST", "/locus/v1/builds/other"},
            {"POST", "/locus/v2/builds/build"},
            {"GET", @build},
            {"GET", @health},
            {"GET", "/health"},
            {"POST", "/build"},
            {"GET", "/"}
          ] do
        assert {400, [{:refusal, {:malformed, sentence}, []}]} =
                 Wire.post(port, path, "", [], method),
               "#{method} #{path}"

        assert sentence =~ "no operation of the builds service"
      end
    end
  end

  describe "a build refused before its stream, nothing spawned" do
    setup do
      # Whatever reaches the spawner shows here; nothing may.
      fake = spawner!(:normal)

      on_exit(fn ->
        assert %{active: 0} = Slots.status(@slots)
      end)

      {:ok, fake: fake}
    end

    test "a header under another key, no header, two, and one that is no header", ctx do
      request = Wire.request("true")

      assert {{:unauthorized, :bad_mac}, []} =
               refused(ctx.port, request, key: :binary.copy(<<1>>, 32))

      body = Wire.body(request)
      header = Wire.header(body)

      for {headers, reason} <- [
            {[], :malformed},
            {[{"x-cyfr-auth", header}, {"x-cyfr-auth", header}], :malformed},
            {[{"x-cyfr-auth", "Bearer test-builder-token"}], :malformed},
            {[{"authorization", "Bearer test-builder-token"}], :malformed}
          ] do
        assert {401, [{:refusal, {:unauthorized, ^reason}, []}]} =
                 Wire.post(ctx.port, @build, body, headers)
      end

      assert spawns(ctx.fake) == []
    end

    test "is answered from the header alone, before any of the body arrives", ctx do
      body = Wire.body(Wire.request("true"))
      header = Wire.header(body, key: :binary.copy(<<1>>, 32))

      # The body is promised and never sent: a service that read it first
      # would wait for it.
      conn =
        Wire.open_raw(ctx.port, [
          "POST #{@build} HTTP/1.1\r\nhost: locus\r\n",
          "content-length: #{byte_size(body)}\r\nx-cyfr-auth: #{header}\r\n\r\n"
        ])

      assert {401, conn} = Wire.status(conn, 2_000)
      assert {{:refusal, {:unauthorized, :bad_mac}, []}, conn} = Wire.line(conn, 2_000)
      Wire.close(conn)
      assert spawns(ctx.fake) == []
    end

    test "a timestamp outside the window, either side", ctx do
      body = Wire.body(Wire.request("true"))
      now = System.system_time(:millisecond)
      window = BuilderProtocol.window_ms()

      for ts <- [now - window - 5_000, now + window + 5_000] do
        assert {{:unauthorized, :outside_window}, []} = refused(ctx.port, body, ts: ts)
      end

      assert spawns(ctx.fake) == []
    end

    test "a nonce seen before, whatever became of the request that carried it", ctx do
      # A deadline already passed: refused, its nonce kept all the same.
      request = Wire.request("true", %{deadline: System.system_time(:millisecond) - 1})
      nonce = Wire.nonce()

      assert {{:timeout, 0}, []} = refused(ctx.port, request, nonce: nonce)
      assert {{:unauthorized, :replayed}, []} = refused(ctx.port, request, nonce: nonce)
      assert {{:timeout, 0}, []} = refused(ctx.port, request)

      # A header that did not verify keeps no nonce.
      other = :binary.copy(<<1>>, 32)
      unverified = Wire.nonce()

      assert {{:unauthorized, :bad_mac}, []} =
               refused(ctx.port, request, key: other, nonce: unverified)

      assert {{:timeout, 0}, []} = refused(ctx.port, request, nonce: unverified)

      assert spawns(ctx.fake) == []
    end

    test "a body other than the one signed: tampered, or longer than the one claimed", ctx do
      body = Wire.body(Wire.request("true"))

      # The same length with one field changed, and the body with a byte more.
      tampered = String.replace(body, ~s("resolve":false), ~s("resolve": true))
      assert tampered != body and byte_size(tampered) == byte_size(body)

      for sent <- [tampered, body <> " "] do
        assert {401, [{:refusal, {:unauthorized, :bad_mac}, []}]} =
                 Wire.post(ctx.port, @build, sent, [{"x-cyfr-auth", Wire.header(body)}])
      end

      assert spawns(ctx.fake) == []
    end

    test "a body declared past the bound, refused without a byte of it read", ctx do
      max = BuilderProtocol.max_request_bytes()
      header = Wire.header("whatever was signed")

      conn =
        Wire.open_raw(ctx.port, [
          "POST #{@build} HTTP/1.1\r\nhost: locus\r\n",
          "content-length: #{max + 1}\r\nx-cyfr-auth: #{header}\r\n\r\n"
        ])

      assert {400, conn} = Wire.status(conn, 2_000)
      assert {{:refusal, {:malformed, sentence}, []}, conn} = Wire.line(conn, 2_000)
      assert sentence == "the request is #{max + 1} bytes; at most #{max} are read"
      Wire.close(conn)
      assert spawns(ctx.fake) == []
    end

    test "a body that declares no length and runs past the bound", ctx do
      max = BuilderProtocol.max_request_bytes()
      body = String.duplicate("x", max + 1)
      size = Integer.to_string(byte_size(body), 16)

      conn =
        Wire.open_raw(ctx.port, [
          "POST #{@build} HTTP/1.1\r\nhost: locus\r\ntransfer-encoding: chunked\r\n",
          "x-cyfr-auth: #{Wire.header(body)}\r\n\r\n",
          [size, "\r\n", body, "\r\n0\r\n\r\n"]
        ])

      assert {400, conn} = Wire.status(conn)
      assert {{:refusal, {:malformed, sentence}, []}, conn} = Wire.line(conn)
      assert sentence =~ "runs past #{max} bytes"
      Wire.close(conn)
      assert spawns(ctx.fake) == []
    end

    test "a body at another version, or at none, naming both ends", ctx do
      wire = "true" |> Wire.request() |> Wire.body() |> Jason.decode!()

      assert {{:protocol_mismatch, 1, 2}, []} =
               refused(ctx.port, Jason.encode!(%{wire | "version" => 2}))

      assert {{:protocol_mismatch, 1, nil}, []} =
               refused(ctx.port, Jason.encode!(Map.delete(wire, "version")))

      assert spawns(ctx.fake) == []
    end

    test "a body that does not read, in the reader's own sentence", ctx do
      wire = "true" |> Wire.request() |> Wire.body() |> Jason.decode!()

      assert {{:malformed, "the body is not a JSON object"}, []} = refused(ctx.port, "[]")

      assert {{:malformed, "token is not a field of this message"}, []} =
               refused(ctx.port, Jason.encode!(Map.put(wire, "token", "test-builder-token")))

      assert {{:malformed, "a reagent is not built from javascript"}, []} =
               refused(ctx.port, Jason.encode!(%{wire | "target_type" => "reagent"}))

      # A sentence quoting a path the request named is cut to the wire's
      # bound rather than failing to encode.
      long = String.duplicate("../", 30_000) <> "escape"
      sources = [%{"path" => long, "base64" => Base.encode64("x")}]

      assert {{:malformed, sentence}, []} =
               refused(ctx.port, Jason.encode!(%{wire | "sources" => sources}))

      assert byte_size(sentence) == BuilderProtocol.max_line_bytes()
      assert spawns(ctx.fake) == []
    end

    test "a deadline already passed", ctx do
      request = Wire.request("true", %{deadline: System.system_time(:millisecond)})
      assert {{:timeout, 0}, []} = refused(ctx.port, request)
      assert spawns(ctx.fake) == []
    end

    test "sources that make no build of their language", ctx do
      request = Wire.request("true", %{sources: %{"src/main.jsx" => "export default 1"}})
      assert {{:malformed, sentence}, []} = refused(ctx.port, request)
      assert sentence =~ "package.json"
      assert spawns(ctx.fake) == []
    end

    test "a toolchain this machine lacks", ctx do
      path = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent")
      on_exit(fn -> System.put_env("PATH", path) end)

      assert {{:unavailable, "the javascript toolchain is not installed in this image"}, []} =
               refused(ctx.port, Wire.request("true"))

      assert spawns(ctx.fake) == []
    end
  end

  describe "a service that holds no key" do
    test "verifies nothing", %{port: port} do
      Application.delete_env(:locus, :request_key)
      assert {{:unauthorized, :bad_mac}, []} = refused(port, Wire.request("true"))
    end
  end

  describe "the build slots" do
    @describetag :requires_node

    setup do
      # Whatever a test did to the instance, the booted one is back for the
      # next module.
      on_exit(fn -> replace_build_slots(Locus.Application.build_slots()) end)
      :ok
    end

    test "at the total cap a build is refused capacity naming it, and nothing is queued", %{
      port: port
    } do
      restart_build_slots(max: 2, key_max: 2)
      _holder = hold(["ath_a", "ath_b"])

      assert {{:capacity, 2}, []} = refused(port, Wire.request("true"))
      assert %{active: 2, queued: 0} = Slots.status(@slots)
    end

    test "at its athanor's cap a build is refused capacity naming that cap, while another athanor builds",
         %{port: port} do
      restart_build_slots(max: 3, key_max: 1)
      _holder = hold([Wire.athanor()])

      assert {{:capacity, 1}, []} = refused(port, Wire.request("true"))
      assert %{active: 1, queued: 0} = Slots.status(@slots)

      script = "mkdir dist && echo ok > dist/index.html"
      other = Wire.request(script, %{athanor_id: "ath_another"})
      assert {200, lines} = Wire.build(port, other)
      assert {:result, %{outputs: %{"index.html" => "ok\n"}}} = List.last(lines)
    end

    test "that are down refuse a build as unavailable, never admit it unaccounted", %{port: port} do
      :ok = Supervisor.terminate_child(Locus.Supervisor, @slots)
      assert %{error: :unavailable} = Slots.status(@slots)

      assert {{:unavailable, sentence}, []} = refused(port, Wire.request("true"))
      assert sentence =~ "build slots"
    end
  end

  describe "a build that runs" do
    @describetag :requires_node

    test "streams its progress, then its result, whose diagnostics are the lines streamed", %{
      port: port
    } do
      script =
        "mkdir -p dist/assets && echo bundling >&2 && echo hi > dist/index.html && echo js > dist/assets/app.js"

      assert {200, lines} = Wire.build(port, Wire.request(script))
      {progress, [terminal]} = Enum.split(lines, -1)

      assert [{:progress, :preparing, _}, {:progress, :compiling, _} | output] = progress
      assert Enum.all?(output, &match?({:progress, :output, _}, &1))
      assert {:progress, :output, "bundling"} in output

      assert {:result, result} = terminal
      assert result.language == :javascript and result.target_type == :tincture
      assert result.outputs == %{"index.html" => "hi\n", "assets/app.js" => "js\n"}

      assert result.diagnostics ==
               Enum.map(progress, fn {:progress, stage, message} -> "#{stage}: #{message}" end)

      wait_until(fn -> match?(%{active: 0, holders: []}, Slots.status(@slots)) end)
    end

    test "and exits non-zero is failed with its status, its log among the diagnostics", %{
      port: port
    } do
      assert {200, lines} = Wire.build(port, Wire.request("echo no such module >&2; exit 7"))
      assert {:refusal, {:failed, {:status, status}}, diagnostics} = List.last(lines)
      assert status != 0
      assert "output: no such module" in diagnostics
      wait_until(fn -> match?(%{active: 0}, Slots.status(@slots)) end)
    end

    test "and writes a log without end answers a log within the wire's bound", %{port: port} do
      script =
        "yes 'a line of a log that goes on and on and on and on' | head -c 3000000 >&2; exit 3"

      assert {200, lines} = Wire.build(port, Wire.request(script))
      assert {:refusal, {:failed, {:status, _}}, diagnostics} = List.last(lines)

      kept = Enum.reduce(diagnostics, 0, &(byte_size(&1) + 1 + &2))
      assert kept <= BuilderProtocol.max_log_bytes()
      assert kept > BuilderProtocol.max_log_bytes() - 100_000
      assert Enum.any?(diagnostics, &(&1 =~ "the rest of it is not kept"))

      # What was streamed is what was kept.
      assert length(lines) - 1 == length(diagnostics)
    end

    test "and leaves more files than the wire carries is refused, never cut to fit", %{port: port} do
      max = BuilderProtocol.max_output_files()
      script = "mkdir dist && i=0 && while [ $i -le #{max} ]; do : > dist/f$i; i=$((i+1)); done"

      assert {200, lines} = Wire.build(port, Wire.request(script))
      assert {:refusal, {:failed, {:status, 0}}, diagnostics} = List.last(lines)
      assert "compiling: the build produced more than #{max} files" in diagnostics
    end

    test "past its deadline is ended with its process group, and answers timeout as its terminal line",
         %{port: port} do
      {script, file} = lingering()
      request = Wire.request(script, %{deadline: System.system_time(:millisecond) + 8_000})

      started = System.monotonic_time(:millisecond)
      assert {200, lines} = Wire.build(port, request)

      assert {:refusal, {:timeout, budget_ms}, diagnostics} = List.last(lines)
      assert budget_ms in 7_000..8_000
      assert "output: running" in diagnostics
      assert System.monotonic_time(:millisecond) - started < 20_000

      # The shell the build ran and the child it started are both gone.
      for os_pid <- pids_in(file), do: wait_until(fn -> not alive?(os_pid) end)
      wait_until(fn -> match?(%{active: 0}, Slots.status(@slots)) end)
    end

    test "whose client leaves is ended within a bound, and its slot goes back", %{port: port} do
      {script, file} = lingering()
      body = Wire.body(Wire.request(script))

      conn = Wire.open(port, @build, body, [{"x-cyfr-auth", Wire.header(body)}])
      assert {200, conn} = Wire.status(conn)
      conn = await_line(conn, {:progress, :output, "running"})

      os_pids = pids_in(file)
      assert Enum.all?(os_pids, &alive?/1)
      assert %{active: 1} = Slots.status(@slots)

      left = System.monotonic_time(:millisecond)
      Wire.close(conn)

      for os_pid <- os_pids, do: wait_until(fn -> not alive?(os_pid) end)
      wait_until(fn -> match?(%{active: 0, holders: []}, Slots.status(@slots)) end)
      assert System.monotonic_time(:millisecond) - left < 10_000

      # The slot is there for the next build.
      assert {200, lines} = Wire.build(port, Wire.request("mkdir dist && echo ok > dist/x"))
      assert {:result, _} = List.last(lines)
    end
  end

  describe "under the spawner" do
    @describetag :requires_node

    setup do
      Application.put_env(:locus, :memory_bytes, 268_435_456)
      on_exit(fn -> Application.delete_env(:locus, :memory_bytes) end)
    end

    test "a build ended at its memory bound answers memory with the configured limit", %{
      port: port
    } do
      fake = spawner!({:exit, %{code: nil, signal: "SIGKILL", memory_exceeded: true}})

      assert {200, lines} = Wire.build(port, Wire.request("true"))
      assert {:refusal, {:memory, 268_435_456}, diagnostics} = List.last(lines)
      assert "output: the command's last words" in diagnostics

      # The bound it was ended at is the one its spawn asked for.
      assert [%{"pool" => "build", "memory_bytes" => 268_435_456}] = spawns(fake)
      wait_until(fn -> match?(%{active: 0}, Slots.status(@slots)) end)
    end

    test "a build killed for any other reason is failed with its signal", %{port: port} do
      _fake = spawner!({:exit, %{code: nil, signal: "SIGKILL", memory_exceeded: false}})

      assert {200, lines} = Wire.build(port, Wire.request("true"))
      assert {:refusal, {:failed, {:signal, "SIGKILL"}}, _diagnostics} = List.last(lines)
    end

    test "a spawner that cannot bound a build runs none: unavailable, naming the option", %{
      port: port
    } do
      fake = spawner!(:memory_unavailable)

      assert {200, lines} = Wire.build(port, Wire.request("true"))
      assert {:refusal, {:unavailable, sentence}, _diagnostics} = List.last(lines)
      assert sentence =~ "writable-cgroups=true"
      assert sentence =~ "runs none"

      # It asked for the bound, and ran nothing when it could not have it.
      assert [%{"memory_bytes" => 268_435_456}] = spawns(fake)
      assert FakeKeeper.requests(fake) == spawns(fake)
      wait_until(fn -> match?(%{active: 0}, Slots.status(@slots)) end)
    end

    test "a pool with no uid free answers capacity", %{port: port} do
      _fake = spawner!(:capacity)

      assert {200, lines} = Wire.build(port, Wire.request("true"))
      assert {:refusal, {:capacity, max}, _} = List.last(lines)
      assert max == Locus.Config.max_concurrent()
    end

    test "cyfr-keeper lost mid-build answers unavailable and gives the slot back", %{port: port} do
      fake = spawner!(:normal)
      body = Wire.body(Wire.request("sleep 3"))

      conn = Wire.open(port, @build, body, [{"x-cyfr-auth", Wire.header(body)}])
      assert {200, conn} = Wire.status(conn)
      wait_until(fn -> spawns(fake) != [] end)
      :ok = FakeKeeper.close(fake)

      conn = await_line(conn, fn line -> match?({:refusal, {:unavailable, _}, _}, line) end)
      Wire.close(conn)
      wait_until(fn -> match?(%{active: 0}, Slots.status(@slots)) end)
    end
  end

  # Reads lines until one is `wanted` (or satisfies it); the answer ending
  # first fails the test.
  defp await_line(conn, wanted) do
    case Wire.line(conn) do
      {:eof, _conn} -> flunk("the answer ended before #{inspect(wanted)}")
      {line, conn} -> if wanted?(line, wanted), do: conn, else: await_line(conn, wanted)
    end
  end

  defp wanted?(line, wanted) when is_function(wanted, 1), do: wanted.(line)
  defp wanted?(line, wanted), do: line == wanted

  # The build slots restarted with caps of the test's own, so the numbers
  # asserted here are the test's and not the environment's.
  defp restart_build_slots(opts) do
    {Prima.Slots, booted} = Locus.Application.build_slots()
    replace_build_slots({Prima.Slots, Keyword.merge(booted, opts)})
  end

  defp replace_build_slots(spec) do
    case Supervisor.terminate_child(Locus.Supervisor, @slots) do
      :ok -> :ok = Supervisor.delete_child(Locus.Supervisor, @slots)
      {:error, :not_found} -> :ok
    end

    {:ok, _pid} = Supervisor.start_child(Locus.Supervisor, spec)
    :ok
  end

  # A process holding one slot for each athanor of `keys`, as the service
  # takes them, for as long as the test runs.
  defp hold(keys) do
    test = self()

    holder =
      spawn(fn ->
        Process.monitor(test)
        results = for key <- keys, do: Slots.acquire(@slots, key, :root, wait_ms: 0)
        send(test, {:held, self(), results})

        receive do
          {:DOWN, _ref, :process, ^test, _reason} -> :ok
        end
      end)

    assert_receive {:held, ^holder, results}, 2_000

    assert Enum.all?(results, &match?({:ok, _}, &1)),
           "could not hold a slot for each of #{inspect(keys)}: #{inspect(results)}"

    holder
  end
end
