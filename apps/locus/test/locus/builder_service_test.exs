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
  toolchain, a cap reached; one refused once its place was made (by its
  sources or its toolchain) leaves no place. After it, the answer is lines: a result, or the
  refusal the build ended with, its diagnostics bounded. A deadline reached
  mid-build ends the build's process group; a client that leaves ends its
  build within a bound and its slot goes back, under the keeper only once
  cyfr-locus reports the build's spawn released; the keeper's memory answers
  are the wire's `memory` and `unavailable`. A build that waits for room
  in the builds count ends by the deadline its request set, and one whose
  client leaves while it waits ends at once.
  """

  # Serves on the application's build slots and, in places, as its keeper.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Prima.Test.Wait

  alias Prima.{BuilderProtocol, Slots}
  alias Locus.Test.{FakeKeeper, Wire}

  @slots Locus.BuildSlots
  @build BuilderProtocol.route(:build)
  @health BuilderProtocol.route(:health)

  setup do
    {:ok, port: Wire.serve!()}
  end

  defp refused(port, request_or_body, opts \\ []) do
    assert {status, [{:refusal, refusal}]} = answer(port, request_or_body, opts)
    assert status == BuilderProtocol.status(refusal)
    refusal
  end

  # An answer's lines as a client keeps them: its terminal line, the log a
  # person reads, and the files a result names (nil for no result).
  defp ended(lines) do
    {log, outputs, terminal} =
      Enum.reduce(lines, {[], BuilderProtocol.outputs(), nil}, fn
        {:progress, stage, message}, {log, outputs, nil} ->
          {[BuilderProtocol.diagnostic(stage, message) | log], outputs, nil}

        {:output, chunk}, {log, outputs, nil} ->
          assert {:ok, outputs} = BuilderProtocol.output(outputs, chunk)
          {log, outputs, nil}

        terminal, {log, outputs, nil} ->
          {log, outputs, terminal}
      end)

    files =
      case terminal do
        {:result, result} ->
          assert {:ok, files} = BuilderProtocol.outputs(outputs, result)
          files

        _other ->
          nil
      end

    {terminal, Enum.reverse(log), files}
  end

  defp answer(port, %{} = request, opts), do: Wire.build(port, request, opts)

  defp answer(port, body, opts) when is_binary(body),
    do: Wire.post(port, @build, body, [{"x-cyfr-auth", Wire.header(body, opts)}])

  # An answer read to its length on a connection left open: its status and
  # its one line.
  defp read_answer(socket, read \\ "") do
    with [head, rest] <- String.split(read, "\r\n\r\n", parts: 2),
         ["HTTP/1.1 " <> status_line | lines] <- String.split(head, "\r\n"),
         [length] <-
           for("content-length: " <> length <- Enum.map(lines, &String.downcase/1), do: length),
         length = String.to_integer(length),
         true <- byte_size(rest) >= length do
      {status, _reason} = Integer.parse(status_line)
      {status, String.trim_trailing(binary_part(rest, 0, length), "\n")}
    else
      _incomplete ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 10_000)
        read_answer(socket, read <> more)
    end
  end

  defp alive?(os_pid) do
    {_out, status} =
      System.cmd("kill", ["-0", os_pid],
        stderr_to_stdout: true,
        env: Locus.Test.ProcessFamily.no_env()
      )

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
    wait_until(
      fn ->
        match?({:ok, text} when byte_size(text) > 0, File.read(file)) and
          length(String.split(File.read!(file), "\n", trim: true)) == 2
      end,
      10_000
    )

    String.split(File.read!(file), "\n", trim: true)
  end

  # The application's keeper for the test: `Locus.Keeper` under its own
  # name, which is how the service finds it, against a fake cyfr-locus.
  defp keeper!(mode) do
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
  defp request_types(fake), do: Enum.map(FakeKeeper.requests(fake), & &1["type"])

  # A build refused once its place was made: the place was dropped, and
  # nothing was spawned in it.
  defp unplaced!(fake) do
    wait_until(fn -> request_types(fake) == ["place", "drop"] end, 5_000)
    assert FakeKeeper.places(fake) == %{}
  end

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
      assert {409, [{:refusal, {:protocol_mismatch, 2, 1}}]} =
               Wire.post(port, @health, ~s({"version":1}))

      assert {400, [{:refusal, {:malformed, sentence}}]} =
               Wire.post(port, @health, ~s({"version":2,"verbose":true}))

      assert sentence =~ "verbose"

      assert {400, [{:refusal, {:malformed, sentence}}]} =
               Wire.post(port, @health, String.duplicate(" ", 5_000) <> ~s({"version":2}))

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
        assert {400, [{:refusal, {:malformed, sentence}}]} =
                 Wire.post(port, path, "", [], method),
               "#{method} #{path}"

        assert sentence =~ "no operation of the builds service"
      end
    end
  end

  describe "a build refused before its stream, nothing spawned" do
    setup do
      # Whatever reaches the keeper shows here; nothing may.
      fake = keeper!(:normal)

      on_exit(fn ->
        assert %{active: 0} = Slots.status(@slots)
      end)

      {:ok, fake: fake}
    end

    test "a header under another key, no header, two, and one that is no header", ctx do
      request = Wire.request("true")

      assert {:unauthorized, :bad_mac} =
               refused(ctx.port, request, key: :binary.copy(<<1>>, 32))

      body = Wire.body(request)
      header = Wire.header(body)

      for {headers, reason} <- [
            {[], :malformed},
            {[{"x-cyfr-auth", header}, {"x-cyfr-auth", header}], :malformed},
            {[{"x-cyfr-auth", "Bearer test-builder-token"}], :malformed},
            {[{"authorization", "Bearer test-builder-token"}], :malformed}
          ] do
        assert {401, [{:refusal, {:unauthorized, ^reason}}]} =
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
      assert {{:refusal, {:unauthorized, :bad_mac}}, conn} = Wire.line(conn, 2_000)
      Wire.close(conn)
      assert spawns(ctx.fake) == []
    end

    test "a timestamp outside the window, either side", ctx do
      body = Wire.body(Wire.request("true"))
      now = System.system_time(:millisecond)
      window = BuilderProtocol.window_ms()

      for ts <- [now - window - 5_000, now + window + 5_000] do
        assert {:unauthorized, :outside_window} = refused(ctx.port, body, ts: ts)
      end

      assert spawns(ctx.fake) == []
    end

    test "a nonce seen before, whatever became of the request that carried it", ctx do
      # A deadline already passed: refused, its nonce kept all the same.
      request = Wire.request("true", %{deadline: System.system_time(:millisecond) - 1})
      nonce = Wire.nonce()

      assert {:timeout, 0} = refused(ctx.port, request, nonce: nonce)
      assert {:unauthorized, :replayed} = refused(ctx.port, request, nonce: nonce)
      assert {:timeout, 0} = refused(ctx.port, request)

      # A header that did not verify keeps no nonce.
      other = :binary.copy(<<1>>, 32)
      unverified = Wire.nonce()

      assert {:unauthorized, :bad_mac} =
               refused(ctx.port, request, key: other, nonce: unverified)

      assert {:timeout, 0} = refused(ctx.port, request, nonce: unverified)

      assert spawns(ctx.fake) == []
    end

    test "a body other than the one signed: tampered, or longer than the one claimed", ctx do
      body = Wire.body(Wire.request("true"))

      # The same length with one field changed, and the body with a byte more.
      tampered = String.replace(body, ~s("resolve":false), ~s("resolve": true))
      assert tampered != body and byte_size(tampered) == byte_size(body)

      for sent <- [tampered, body <> " "] do
        assert {401, [{:refusal, {:unauthorized, :bad_mac}}]} =
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
      assert {{:refusal, {:malformed, sentence}}, conn} = Wire.line(conn, 2_000)
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
      assert {{:refusal, {:malformed, sentence}}, conn} = Wire.line(conn)
      assert sentence =~ "runs past #{max} bytes"
      Wire.close(conn)
      assert spawns(ctx.fake) == []
    end

    test "a client still sending a chunked body past the bound when it is refused reads the refusal, not a reset",
         ctx do
      max = BuilderProtocol.max_request_bytes()
      body = String.duplicate("x", max + 65_536)
      options = [:binary, active: false, packet: :raw, show_econnreset: true]
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, ctx.port, options, 5_000)

      # One chunk holding the whole body, of which the bound and a byte past
      # it are on the connection when the refusal is made.
      :ok =
        :gen_tcp.send(socket, [
          "POST #{@build} HTTP/1.1\r\nhost: locus\r\ntransfer-encoding: chunked\r\n",
          "x-cyfr-auth: #{Wire.header(body)}\r\n\r\n",
          Integer.to_string(byte_size(body), 16),
          "\r\n",
          binary_part(body, 0, max + 1)
        ])

      {status, line} = read_answer(socket)
      assert status == 400

      assert {:ok, {:refusal, {:malformed, sentence}}} = BuilderProtocol.read_line(line)
      assert sentence == "the request runs past #{max} bytes; at most #{max} are read"

      # The rest of the chunk and the body's end, written after the refusal
      # was read: every write is taken, and the connection closes cleanly.
      rest = binary_part(body, max + 1, byte_size(body) - max - 1)

      for piece <- [binary_part(rest, 0, 32_768), binary_part(rest, 32_768, 32_767)] do
        assert :gen_tcp.send(socket, piece) == :ok
      end

      assert :gen_tcp.send(socket, "\r\n0\r\n\r\n") == :ok
      assert :gen_tcp.recv(socket, 0, 10_000) == {:error, :closed}
      :gen_tcp.close(socket)
      assert spawns(ctx.fake) == []
    end

    test "a body at another version, or at none, naming both ends", ctx do
      wire = "true" |> Wire.request() |> Wire.body() |> Jason.decode!()

      assert {:protocol_mismatch, 2, 1} =
               refused(ctx.port, Jason.encode!(%{wire | "version" => 1}))

      assert {:protocol_mismatch, 2, nil} =
               refused(ctx.port, Jason.encode!(Map.delete(wire, "version")))

      assert spawns(ctx.fake) == []
    end

    test "a body that does not read, in the reader's own sentence", ctx do
      wire = "true" |> Wire.request() |> Wire.body() |> Jason.decode!()

      assert {:malformed, "the body is not a JSON object"} = refused(ctx.port, "[]")

      assert {:malformed, "token is not a field of this message"} =
               refused(ctx.port, Jason.encode!(Map.put(wire, "token", "test-builder-token")))

      assert {:malformed, "a reagent is not built from javascript"} =
               refused(ctx.port, Jason.encode!(%{wire | "target_type" => "reagent"}))

      # A sentence quoting a path the request named is cut to the wire's
      # bound rather than failing to encode.
      long = String.duplicate("../", 30_000) <> "escape"
      sources = [%{"path" => long, "base64" => Base.encode64("x")}]

      assert {:malformed, sentence} =
               refused(ctx.port, Jason.encode!(%{wire | "sources" => sources}))

      assert byte_size(sentence) == BuilderProtocol.max_line_bytes()
      assert spawns(ctx.fake) == []
    end

    test "a deadline already passed", ctx do
      request = Wire.request("true", %{deadline: System.system_time(:millisecond)})
      assert {:timeout, 0} = refused(ctx.port, request)
      assert FakeKeeper.requests(ctx.fake) == []
    end

    test "sources that make no build of their language", ctx do
      request = Wire.request("true", %{sources: %{"src/main.jsx" => "export default 1"}})
      assert {:malformed, sentence} = refused(ctx.port, request)
      assert sentence =~ "package.json"
      unplaced!(ctx.fake)
    end

    test "a toolchain this machine lacks", ctx do
      path = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent")
      on_exit(fn -> System.put_env("PATH", path) end)

      assert {:unavailable, "the javascript toolchain is not installed in this image"} =
               refused(ctx.port, Wire.request("true"))

      unplaced!(ctx.fake)
    end
  end

  describe "a service that holds no key" do
    test "verifies nothing", %{port: port} do
      Application.delete_env(:locus, :request_key)
      assert {:unauthorized, :bad_mac} = refused(port, Wire.request("true"))
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

      assert {:capacity, 2} = refused(port, Wire.request("true"))
      assert %{active: 2, queued: 0} = Slots.status(@slots)
    end

    test "at its athanor's cap a build is refused capacity naming that cap, while another athanor builds",
         %{port: port} do
      restart_build_slots(max: 3, key_max: 1)
      _holder = hold([Wire.athanor()])

      assert {:capacity, 1} = refused(port, Wire.request("true"))
      assert %{active: 1, queued: 0} = Slots.status(@slots)

      script = "mkdir dist && echo ok > dist/index.html"
      other = Wire.request(script, %{athanor_id: "ath_another"})
      assert {200, lines} = Wire.build(port, other)
      assert {{:result, _}, _log, %{"index.html" => "ok\n"}} = ended(lines)
    end

    test "that are down refuse a build as unavailable, never admit it unaccounted", %{port: port} do
      :ok = Supervisor.terminate_child(Locus.Supervisor, @slots)
      assert %{error: :unavailable} = Slots.status(@slots)

      assert {:unavailable, sentence} = refused(port, Wire.request("true"))
      assert sentence =~ "build slots"
    end
  end

  describe "a build that runs" do
    @describetag :requires_node

    test "streams its progress and its files, then its result; a person reads the lines streamed, in order",
         %{port: port} do
      script =
        "mkdir -p dist/assets && echo bundling >&2 && echo hi > dist/index.html && echo js > dist/assets/app.js"

      assert {200, lines} = Wire.build(port, Wire.request(script))
      progress = for {:progress, _stage, _message} = line <- lines, do: line

      assert [{:progress, :preparing, _}, {:progress, :compiling, _} | output] = progress
      assert Enum.all?(output, &match?({:progress, :output, _}, &1))
      assert {:progress, :output, "bundling"} in output

      # Every line but the last is progress or output, the outputs after
      # the build's log; no terminal line carries the log again.
      {terminal, log, files} = ended(lines)
      assert {:result, result} = terminal
      assert result.language == :javascript and result.target_type == :tincture
      assert files == %{"index.html" => "hi\n", "assets/app.js" => "js\n"}
      refute Map.has_key?(result, :diagnostics)

      # The log a person reads is the lines the terminal line carried
      # before: each progress line as `stage: message`, in the order streamed.
      assert log ==
               Enum.map(progress, fn {:progress, stage, message} -> "#{stage}: #{message}" end)

      assert [
               "preparing: Preparing source files...",
               "compiling: Building tincture (npm ci && npm run build)..." | _
             ] = log

      wait_until(fn -> match?(%{active: 0, holders: []}, Slots.status(@slots)) end, 10_000)
    end

    test "and exits non-zero is failed with its status, its log among the diagnostics", %{
      port: port
    } do
      assert {200, lines} = Wire.build(port, Wire.request("echo no such module >&2; exit 7"))
      assert {{:refusal, {:failed, {:status, status}}}, diagnostics, nil} = ended(lines)
      assert status != 0
      assert "output: no such module" in diagnostics
      wait_until(fn -> match?(%{active: 0}, Slots.status(@slots)) end, 10_000)
    end

    test "and writes a log without end answers a log within the wire's bound", %{port: port} do
      script =
        "yes 'a line of a log that goes on and on and on and on' | head -c 3000000 >&2; exit 3"

      assert {200, lines} = Wire.build(port, Wire.request(script))
      assert {{:refusal, {:failed, {:status, _}}}, diagnostics, nil} = ended(lines)

      # The log is charged as the progress lines streamed, each encoded with
      # its newline, and the diagnostics a person reads are those lines.
      kept =
        Enum.reduce(Enum.drop(lines, -1), 0, fn {:progress, stage, message}, bytes ->
          {:ok, line} = BuilderProtocol.encode_progress(stage, message)
          bytes + byte_size(line) + 1
        end)

      assert kept <= BuilderProtocol.max_log_bytes()
      assert kept > BuilderProtocol.max_log_bytes() - 100_000
      assert Enum.reduce(diagnostics, 0, &(byte_size(&1) + 1 + &2)) < kept
      assert Enum.any?(diagnostics, &(&1 =~ "the rest of it is not kept"))

      # What was streamed is what was kept.
      assert length(lines) - 1 == length(diagnostics)
    end

    test "and leaves more files than the wire carries is refused, never cut to fit", %{port: port} do
      max = BuilderProtocol.max_output_files()
      script = "mkdir dist && i=0 && while [ $i -le #{max} ]; do : > dist/f$i; i=$((i+1)); done"

      assert {200, lines} = Wire.build(port, Wire.request(script))
      assert {{:refusal, {:failed, {:status, 0}}}, diagnostics, nil} = ended(lines)
      assert "compiling: the build produced more than #{max} files" in diagnostics
    end

    test "past its deadline is ended with its process group, and answers timeout as its terminal line",
         %{port: port} do
      {script, file} = lingering()
      request = Wire.request(script, %{deadline: System.system_time(:millisecond) + 8_000})

      started = System.monotonic_time(:millisecond)
      assert {200, lines} = Wire.build(port, request)

      assert {{:refusal, {:timeout, budget_ms}}, diagnostics, nil} = ended(lines)
      assert budget_ms in 7_000..8_000
      assert "output: running" in diagnostics
      assert System.monotonic_time(:millisecond) - started < 20_000

      # The shell the build ran and the child it started are both gone.
      for os_pid <- pids_in(file), do: wait_until(fn -> not alive?(os_pid) end, 10_000)
      wait_until(fn -> match?(%{active: 0}, Slots.status(@slots)) end, 10_000)
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

      for os_pid <- os_pids, do: wait_until(fn -> not alive?(os_pid) end, 10_000)
      wait_until(fn -> match?(%{active: 0, holders: []}, Slots.status(@slots)) end, 10_000)
      assert System.monotonic_time(:millisecond) - left < 10_000

      # The slot is there for the next build.
      assert {200, lines} = Wire.build(port, Wire.request("mkdir dist && echo ok > dist/x"))
      assert {{:result, _}, _log, %{"x" => "ok\n"}} = ended(lines)
    end
  end

  describe "what a build holds" do
    @describetag :requires_node

    test "a slow reader of a 64 MiB result: the node never holds over its 8 MiB of it", %{
      port: port
    } do
      bound = Locus.Output.bounds().builds.answering
      size = BuilderProtocol.max_output_bytes() - 4096
      script = "mkdir dist && head -c #{size} /dev/urandom > dist/blob.bin"
      body = Wire.body(Wire.request(script))
      base = held_by_the_node()

      conn = Wire.open(port, @build, body, [{"x-cyfr-auth", Wire.header(body)}])
      assert {200, conn} = Wire.status(conn, 120_000)
      {lines, peak} = read_slowly(conn, base, [], 0)

      # The node held no more of the build's output than its bound, however
      # slowly its reader read, and the count says no more than that.
      assert peak <= bound, "the node held #{peak} bytes of a build's output past #{bound}"

      assert {{:result, _}, _log, %{"blob.bin" => blob}} = ended(lines)
      assert byte_size(blob) == size
      wait_until(fn -> builds_held() == 0 end, 10_000, "the build's grant returned")
    end

    test "a failed exit after chunks gives back what it held; the client keeps nothing", %{
      port: port
    } do
      # A name ustar cannot carry: tar writes the file before it, then fails.
      long = Enum.map_join(1..2, "/", fn n -> String.duplicate("#{n}", 200) end)

      script =
        "mkdir -p dist/#{Path.dirname(long)} && head -c 1000000 /dev/zero > dist/a && " <>
          "echo x > dist/#{long}"

      assert {200, lines} = Wire.build(port, Wire.request(script))
      assert Enum.any?(lines, &match?({:output, %{path: "a"}}, &1))
      assert {{:refusal, {:failed, {:status, status}}}, _log, nil} = ended(lines)
      assert status != 0
      wait_until(fn -> builds_held() == 0 end, 10_000, "the build's grant returned")
    end

    test "a reader that stops reading ends the build at its deadline, and its count and slot go back",
         %{port: port} do
      script = "mkdir dist && head -c 33554432 /dev/zero > dist/big"
      deadline = System.system_time(:millisecond) + 20_000
      body = Wire.body(Wire.request(script, %{deadline: deadline}))

      conn = Wire.open(port, @build, body, [{"x-cyfr-auth", Wire.header(body)}])
      assert {200, conn} = Wire.status(conn, 60_000)
      conn = await_line(conn, fn line -> match?({:output, _}, line) end)

      # The reader reads no more; past the deadline the build is ended, its
      # count given back and its slot free, and nothing more is written.
      wait_until(
        fn -> System.system_time(:millisecond) > deadline and builds_held() == 0 end,
        40_000,
        "the build ended at its deadline and its grant returned"
      )

      wait_until(fn -> match?(%{active: 0, holders: []}, Slots.status(@slots)) end, 10_000)
      Wire.close(conn)
    end

    test "a reader that leaves gives back the build's count", %{port: port} do
      script = "mkdir dist && head -c 33554432 /dev/zero > dist/big"
      body = Wire.body(Wire.request(script))

      conn = Wire.open(port, @build, body, [{"x-cyfr-auth", Wire.header(body)}])
      assert {200, conn} = Wire.status(conn, 60_000)
      conn = await_line(conn, fn line -> match?({:output, _}, line) end)
      Wire.close(conn)

      wait_until(fn -> builds_held() == 0 end, 20_000, "the build's grant returned")
      wait_until(fn -> match?(%{active: 0, holders: []}, Slots.status(@slots)) end, 10_000)
    end

    test "a build that waited for room ends at the deadline its request set, its wait spent from its budget",
         %{port: port} do
      holder = hold_builds(Locus.Output.bounds().builds.answering)
      deadline = System.system_time(:millisecond) + 6_000
      request = Wire.request("sleep 60", %{deadline: deadline})
      task = Task.async(fn -> Wire.build(port, request) end)
      wait_until(fn -> builds_waiting() == 1 end, 5_000, "the build waits for room")

      # sleep-ok: the count is held until shortly before the build's deadline, which is the case.
      Process.sleep(max(deadline - 1_000 - System.system_time(:millisecond), 0))
      send(holder, :give_back)

      assert {200, lines} = Task.await(task, 30_000)
      answered = System.system_time(:millisecond)
      assert {{:refusal, {:timeout, budget_ms}}, _log, nil} = ended(lines)
      assert budget_ms in 5_000..6_000
      assert answered < deadline + 2_000, "answered #{answered - deadline} ms past its deadline"
      wait_until(fn -> builds_held() == 0 end, 10_000, "the build's grant returned")
    end

    test "a build waiting for room whose client leaves ends at once, and its slot goes back", %{
      port: port
    } do
      _holder = hold_builds(Locus.Output.bounds().builds.answering)
      body = Wire.body(Wire.request("true"))

      conn = Wire.open(port, @build, body, [{"x-cyfr-auth", Wire.header(body)}])
      assert {200, conn} = Wire.status(conn)
      wait_until(fn -> builds_waiting() == 1 end, 5_000, "the build waits for room")

      left = System.monotonic_time(:millisecond)
      Wire.close(conn)

      wait_until(
        fn ->
          builds_waiting() == 0 and match?(%{active: 0, holders: []}, Slots.status(@slots))
        end,
        20_000,
        "the build's process gone and its slot back"
      )

      gone = System.monotonic_time(:millisecond) - left
      assert gone < 3_000, "the build's process was gone #{gone} ms after its client left"
    end
  end

  # What the builds role's count holds now, and how many ask it for room.
  defp builds_held, do: Locus.Output.held(Locus.Output.server(:builds)).answering
  defp builds_waiting, do: Locus.Output.held(Locus.Output.server(:builds)).waiting

  # A process holding `bytes` of the builds role's count until it is sent
  # `:give_back`, or the test ends.
  defp hold_builds(bytes) do
    test = self()

    holder =
      spawn(fn ->
        Process.monitor(test)
        by = System.monotonic_time(:millisecond) + 10_000
        {:ok, grant} = Locus.Output.reserve(Locus.Output.server(:builds), bytes, by)
        send(test, {:holding, self()})

        receive do
          :give_back -> Locus.Output.return(grant)
          {:DOWN, _ref, :process, ^test, _reason} -> :ok
        end
      end)

    assert_receive {:holding, ^holder}, 10_000
    holder
  end

  # Every binary the node's processes but this test's hold once each has
  # collected its garbage, each counted once.
  defp held_by_the_node do
    test = self()

    for pid <- Process.list(), pid != test, do: :erlang.garbage_collect(pid)

    Process.list()
    |> Enum.reject(&(&1 == test))
    |> Enum.flat_map(fn pid ->
      case Process.info(pid, :binary) do
        {:binary, binaries} -> binaries
        nil -> []
      end
    end)
    |> Map.new(fn {id, size, _refs} -> {id, size} end)
    |> Map.values()
    |> Enum.sum()
  end

  # Reads the answer as a slow reader does: every 64 lines it stops for a
  # while, and what the node then holds past `base` is taken, the most of
  # it answered beside the lines read.
  defp read_slowly(conn, base, lines, peak) do
    peak =
      if rem(length(lines), 64) == 0 do
        # sleep-ok: a reader that stops reading for a while is the case.
        Process.sleep(200)
        assert builds_held() <= Locus.Output.bounds().builds.answering
        max(peak, held_by_the_node() - base)
      else
        peak
      end

    case Wire.line(conn, 60_000) do
      {:eof, conn} ->
        Wire.close(conn)
        {Enum.reverse(lines), peak}

      {line, conn} ->
        read_slowly(conn, base, [line | lines], peak)
    end
  end

  describe "under the keeper" do
    @describetag :requires_node

    test "a build ended at its memory bound answers memory with a build's bound", %{
      port: port
    } do
      fake = keeper!({:exit, %{code: nil, signal: "SIGKILL", memory: "cap"}})

      assert {200, lines} = Wire.build(port, Wire.request("true"))
      bound = Prima.LocusPool.build_cap_bytes()
      assert {{:refusal, {:memory, ^bound}}, diagnostics, nil} = ended(lines)
      assert "output: the command's last words" in diagnostics

      # The bound it was ended at is the keeper's for a build: its spawn
      # names none.
      assert [%{"pool" => "build"} = spawn] = spawns(fake)
      refute Map.has_key?(spawn, "memory_bytes") or Map.has_key?(spawn, "cpu_quota")
      wait_until(fn -> match?(%{active: 0}, Slots.status(@slots)) end, 10_000)
    end

    test "a build's place is made for its athanor, of any id the other Locus wires take, " <>
           "before it is prepared, named by its spawn, and freed once the build is gone",
         %{port: port} do
      fake = keeper!({:exit, %{code: nil, signal: "SIGKILL", memory: nil}})
      request = Wire.request("true", %{athanor_id: "family@example"})

      assert {200, _lines} = Wire.build(port, request)
      wait_until(fn -> FakeKeeper.places(fake) == %{} end, 10_000)
      [placed, spawned] = FakeKeeper.requests(fake)

      assert %{
               placed: Map.take(placed, ~w(type kind athanor)),
               named: spawned["place"],
               spawned: spawned["type"]
             } == %{
               placed: %{"type" => "place", "kind" => "build", "athanor" => request.athanor_id},
               named: placed["id"],
               spawned: "spawn"
             }
    end

    # A build's place waits for the keeper's room: the build waits past the
    # room's wait, and is run once placed or refused naming no_memory.
    test "a build whose place the keeper answers past 5 s runs, and one it refuses for room is unavailable naming no_memory",
         %{port: port} do
      fake = keeper!({:place_held, self()})

      placed = Task.async(fn -> Wire.build(port, Wire.request("true")) end)
      assert_receive {:place_held, first}, 10_000
      assert Task.yield(placed, 6_000) == nil
      :ok = FakeKeeper.answer_place(fake, first, :placed)
      wait_until(fn -> spawns(fake) != [] end, 10_000)
      assert [%{"place" => ^first}] = spawns(fake)
      assert {200, _lines} = Task.await(placed, 120_000)

      held = %{"need" => 838_860_800, "free" => 0, "mine" => [], "others_bytes" => 0}
      refused = Task.async(fn -> Wire.build(port, Wire.request("true")) end)
      assert_receive {:place_held, second}, 10_000
      assert Task.yield(refused, 6_000) == nil
      :ok = FakeKeeper.answer_place(fake, second, {:no_memory, held})

      refusal = {:unavailable, "cyfr-locus could not hold the build (no_memory)"}

      assert Task.await(refused, 30_000) ==
               {BuilderProtocol.status(refusal), [{:refusal, refusal}]}

      assert length(spawns(fake)) == 1
      wait_until(fn -> match?(%{active: 0}, Slots.status(@slots)) end, 10_000)
    end

    test "a build killed for any other reason is failed with its signal", %{port: port} do
      _fake = keeper!({:exit, %{code: nil, signal: "SIGKILL", memory: nil}})

      assert {200, lines} = Wire.build(port, Wire.request("true"))
      assert {:refusal, {:failed, {:signal, "SIGKILL"}}} = List.last(lines)
    end

    test "a build ended at a limit above its own is a memory end that says CYFR ran out for builds",
         %{port: port} do
      _fake = keeper!({:exit, %{code: nil, signal: "SIGKILL", memory: "machine"}})

      assert {200, lines} = Wire.build(port, Wire.request("true"))
      assert {:refusal, refusal} = List.last(lines)
      assert refusal == {:memory, :machine}

      said = Prima.BuilderProtocol.describe_refusal(refusal)
      assert said == "CYFR ran out of memory for builds and the build was ended"
      refute said =~ ~r/bound|SIGKILL|[0-9]/
    end

    test "a build ended for memory at a limit the kernel cannot name is a memory end that names none",
         %{port: port} do
      _fake = keeper!({:exit, %{code: nil, signal: "SIGKILL", memory: "either"}})

      assert {200, lines} = Wire.build(port, Wire.request("true"))
      assert {:refusal, refusal} = List.last(lines)
      assert refusal == {:memory, :either}

      said = Prima.BuilderProtocol.describe_refusal(refusal)
      assert said == "the build ran out of memory and was ended"
      refute said =~ ~r/bound|limit|SIGKILL|[0-9]/
    end

    test "a keeper that cannot bound a build runs none: unavailable, naming the option", %{
      port: port
    } do
      fake = keeper!(:memory_unavailable)

      assert {200, lines} = Wire.build(port, Wire.request("true"))
      assert {:refusal, {:unavailable, sentence}} = List.last(lines)
      assert sentence =~ "writable-cgroups=true"
      assert sentence =~ "runs none"

      # It asked for its spawn, in the build's place, and ran nothing when
      # the keeper could not bound it; the refused spawn freed the place.
      assert [_spawn] = spawns(fake)
      assert request_types(fake) == ["place", "spawn"]
      assert FakeKeeper.places(fake) == %{}
      wait_until(fn -> match?(%{active: 0}, Slots.status(@slots)) end, 10_000)
    end

    test "a pool with no uid free answers capacity", %{port: port} do
      _fake = keeper!(:capacity)

      assert {200, lines} = Wire.build(port, Wire.request("true"))
      assert {:refusal, {:capacity, max}} = List.last(lines)
      assert max == Locus.Config.max_concurrent()
    end

    test "cyfr-locus lost mid-build answers unavailable and gives the slot back", %{port: port} do
      fake = keeper!(:normal)
      body = Wire.body(Wire.request("sleep 3"))

      conn = Wire.open(port, @build, body, [{"x-cyfr-auth", Wire.header(body)}])
      assert {200, conn} = Wire.status(conn)
      wait_until(fn -> spawns(fake) != [] end, 10_000)
      :ok = FakeKeeper.close(fake)

      conn = await_line(conn, fn line -> match?({:refusal, {:unavailable, _}}, line) end)
      Wire.close(conn)
      wait_until(fn -> match?(%{active: 0}, Slots.status(@slots)) end, 10_000)
    end

    test "a build whose client left holds its slot until cyfr-locus reports its spawn released, " <>
           "however long past the cancel's bound that takes",
         %{port: port} do
      fake = keeper!(:normal)
      :ok = FakeKeeper.hold_releases(fake, self())
      {script, file} = lingering()
      body = Wire.body(Wire.request(script))

      conn = Wire.open(port, @build, body, [{"x-cyfr-auth", Wire.header(body)}])
      assert {200, conn} = Wire.status(conn)
      conn = await_line(conn, {:progress, :output, "running"})
      os_pids = pids_in(file)
      Wire.close(conn)

      # The cancel asks cyfr-locus to end the spawn, which it does not yet.
      assert_receive {:release_held, _spawn_id}, 10_000

      log =
        capture_log(fn ->
          # sleep-ok: past the service's fixed 15 s bound for a cancelled build to end, which no event marks.
          Process.sleep(16_000)
        end)

      assert %{active: 1} = Slots.status(@slots)
      assert Enum.all?(os_pids, &alive?/1)
      assert log =~ "its slot is held until cyfr-locus releases it"

      # cyfr-locus ends it and reports it released: only then is the slot free.
      :ok = FakeKeeper.carry_releases(fake)
      for os_pid <- os_pids, do: wait_until(fn -> not alive?(os_pid) end, 10_000)
      wait_until(fn -> match?(%{active: 0, holders: []}, Slots.status(@slots)) end, 10_000)
    end

    test "a build whose connection's process is killed holds its slot until cyfr-locus " <>
           "reports its spawn released",
         %{port: port} do
      fake = keeper!(:normal)
      :ok = FakeKeeper.hold_releases(fake, self())
      {script, file} = lingering()
      body = Wire.body(Wire.request(script))

      conn = Wire.open(port, @build, body, [{"x-cyfr-auth", Wire.header(body)}])
      assert {200, conn} = Wire.status(conn)
      conn = await_line(conn, {:progress, :output, "running"})
      os_pids = pids_in(file)

      # The connection's process holds the slot; its kill takes the build's
      # process with it, and the keeper's client asks cyfr-locus to end the
      # spawn of an owner gone, which it does not yet.
      assert %{holders: [%{pid: "#PID" <> holder}]} = Slots.status(@slots)
      holder = :erlang.list_to_pid(String.to_charlist(holder))
      Process.exit(holder, :kill)
      assert_receive {:release_held, _spawn_id}, 10_000
      Wire.close(conn)

      assert %{active: 1} = Slots.status(@slots)
      assert Enum.all?(os_pids, &alive?/1)

      :ok = FakeKeeper.carry_releases(fake)
      for os_pid <- os_pids, do: wait_until(fn -> not alive?(os_pid) end, 10_000)
      wait_until(fn -> match?(%{active: 0, holders: []}, Slots.status(@slots)) end, 10_000)
    end

    test "a build past its deadline whose client left frees its only slot on cyfr-locus's release, " <>
           "its last line waiting for no one",
         %{port: port} do
      on_exit(fn -> replace_build_slots(Locus.Application.build_slots()) end)
      restart_build_slots(max: 1, key_max: 1)
      fake = keeper!(:normal)
      :ok = FakeKeeper.hold_releases(fake, self())
      {script, file} = lingering()
      request = Wire.request(script, %{deadline: System.system_time(:millisecond) + 4_000})
      body = Wire.body(request)

      conn = Wire.open(port, @build, body, [{"x-cyfr-auth", Wire.header(body)}])
      assert {200, conn} = Wire.status(conn)
      conn = await_line(conn, {:progress, :output, "running"})
      os_pids = pids_in(file)

      # The deadline ends the run, which asks cyfr-locus to end the spawn;
      # then the client leaves, and the cancel's bound passes with the
      # release still held, each cancel taken by the run.
      assert_receive {:release_held, _spawn_id}, 10_000
      Wire.close(conn)

      capture_log(fn ->
        # sleep-ok: past the service's fixed 15 s bound for a cancelled build to end, which no event marks.
        Process.sleep(16_000)
      end)

      :ok = FakeKeeper.carry_releases(fake)
      for os_pid <- os_pids, do: wait_until(fn -> not alive?(os_pid) end, 10_000)

      # The build answers its deadline to no one, and the slot is the next build's.
      wait_until(fn -> match?(%{active: 0, holders: []}, Slots.status(@slots)) end, 10_000)
      assert {200, lines} = Wire.build(port, Wire.request("true"))
      refute match?({:refusal, {:capacity, _}}, List.last(lines))
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
