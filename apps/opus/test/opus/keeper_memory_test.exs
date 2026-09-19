# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.KeeperMemoryTest do
  @moduledoc """
  The `cyfr-spawn` client holds every runner to a memory bound, against a
  scripted keeper on a socket the test holds the keeper's end of: every
  spawn carries the pool's `:runner_memory_bytes` (or the bound the client
  was started with) and no spawn can ask for none; a malformed bound stops
  the client before any runner is started; a runner the keeper reports
  ended at its bound reaches its handle as the signal that ended it, is
  logged as ended at its bound, and is tainted, released and never handed
  out again by the pool; and a spawn the keeper cannot bound is refused
  typed, logged naming what the deployment lacks, and never retried
  without its bound.
  """

  # The application environment's `:runner_memory_bytes` is set by one
  # test, and the pool test registers the client under its own name.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Opus.Test.Wait

  alias Opus.Keeper.Spawn
  alias Opus.{RunnerPool, RunnerProcess}

  @stream_attach 3

  @spec_env %{"OPUS_ROLE" => "runner", "OPUS_RUNNER_ID" => "runner_1"}
  @default 402_653_184

  # The keeper's vectors, which the repository carries and a checkout of
  # Opus alone (the independence build) does not.
  @vectors Path.expand("../../../../tests/fixtures/spawn_protocol.json", __DIR__)
  @no_vectors if(File.exists?(@vectors),
                do: false,
                else:
                  "the keeper's vectors (tests/fixtures/spawn_protocol.json) are not in this checkout"
              )

  setup do
    unique = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "opus_memory_#{unique}.sock")
    dir = Path.join(System.tmp_dir!(), "opus_memory_attach_#{unique}")
    File.rm(path)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    {:ok, listener} = :socket.open(:local, :stream)
    :ok = :socket.bind(listener, %{family: :local, path: path})
    :ok = :socket.listen(listener)

    on_exit(fn ->
      :socket.close(listener)
      File.rm(path)
      File.rm_rf(dir)
    end)

    {:ok, listener: listener, path: path, dir: dir, unique: unique}
  end

  # A client on a fresh channel: its name and the keeper's end.
  defp start_client!(ctx, opts \\ []) do
    {spawner, keeper_end} = channel(ctx)
    name = Keyword.get(opts, :name, :"memory_keeper_#{ctx.unique}")

    start_supervised!(
      Supervisor.child_spec(
        {Spawn, [channel: keeper_end, attach_dir: ctx.dir, name: name] ++ opts},
        id: {Spawn, name},
        restart: :temporary
      )
    )

    on_exit(fn -> :socket.close(spawner) end)
    {name, spawner}
  end

  defp channel(%{listener: listener, path: path}) do
    {:ok, keeper_end} = :socket.open(:local, :stream)
    :ok = :socket.connect(keeper_end, %{family: :local, path: path})
    {:ok, spawner} = :socket.accept(listener)
    {spawner, keeper_end}
  end

  defp start_handle!(name, id \\ "runner_1") do
    spec = %{runner: id, argv: ["/app/bin/opus", "start"], env: @spec_env, server: name}

    start_supervised!({RunnerProcess, id: id, keeper: Spawn, spec: spec, owner: self()},
      id: {RunnerProcess, id}
    )
  end

  # The next line the client sent the keeper, and what followed it.
  defp request(spawner, buffer \\ "") do
    case :binary.split(buffer, "\n") do
      [line, rest] ->
        {Jason.decode!(line), rest}

      [partial] ->
        {:ok, data} = :socket.recv(spawner, 0, 5_000)
        request(spawner, partial <> data)
    end
  end

  defp next_request(spawner), do: spawner |> request() |> elem(0)

  defp silent?(spawner, ms), do: :socket.recv(spawner, 0, ms) == {:error, :timeout}

  defp reply(spawner, message), do: :ok = :socket.send(spawner, [Jason.encode!(message), ?\n])

  defp attach!(dir, token) do
    {:ok, relay} =
      :gen_tcp.connect({:local, Path.join(dir, "attach.sock")}, 0, [:binary, active: false])

    :ok = :gen_tcp.send(relay, [<<@stream_attach, byte_size(token)::32>>, token])
    relay
  end

  defp spawn_id(n), do: n |> Integer.to_string(16) |> String.pad_leading(32, "0")

  describe "the bound every spawn carries" do
    test "is the pool's setting, its default unset, and the client's own when started with one",
         ctx do
      {name, spawner} = start_client!(ctx)
      _handle = start_handle!(name)

      assert %{"type" => "spawn", "pool" => "runner", "memory_bytes" => @default} =
               next_request(spawner)

      previous = Application.fetch_env(:opus, :runner_memory_bytes)
      Application.put_env(:opus, :runner_memory_bytes, 268_435_456)

      try do
        {configured, spawner} = start_client!(%{ctx | unique: ctx.unique + 1})
        _handle = start_handle!(configured, "runner_2")
        assert %{"memory_bytes" => 268_435_456} = next_request(spawner)
      after
        case previous do
          {:ok, value} -> Application.put_env(:opus, :runner_memory_bytes, value)
          :error -> Application.delete_env(:opus, :runner_memory_bytes)
        end
      end

      {own, spawner} = start_client!(%{ctx | unique: ctx.unique + 2}, memory_bytes: 16_777_216)
      _handle = start_handle!(own, "runner_3")
      assert %{"memory_bytes" => 16_777_216} = next_request(spawner)
    end

    test "a malformed bound, or none, stops the client before a runner is asked for", ctx do
      Process.flag(:trap_exit, true)

      for bound <- [nil, 0, 16_777_215, 1_099_511_627_777, -1, 1.0e9, "1G", :unbounded] do
        {_spawner, keeper_end} = channel(ctx)

        assert {:error, {:keeper_unavailable, {:malformed, :runner_memory_bytes}}} =
                 Spawn.start_link(
                   channel: keeper_end,
                   attach_dir: ctx.dir,
                   memory_bytes: bound,
                   name: :"memory_refused_#{ctx.unique}"
                 )
      end
    end

    @tag skip: @no_vectors
    test "has the shape of the keeper's own runner spawn vector", ctx do
      vectors = @vectors |> File.read!() |> Jason.decode!()

      vector =
        Enum.find(vectors["valid_requests"], &(&1["pool"] == "runner" and &1["memory_bytes"]))

      {name, spawner} = start_client!(ctx, memory_bytes: vector["memory_bytes"])
      _handle = start_handle!(name)
      sent = next_request(spawner)

      assert Enum.sort(Map.keys(sent)) == Enum.sort(Map.keys(vector))

      assert Map.take(sent, ~w(v type pool memory_bytes control)) ==
               Map.take(vector, ~w(v type pool memory_bytes control))
    end
  end

  describe "a runner ended at its bound" do
    @tag skip: @no_vectors
    test "reaches its handle as the signal that ended it, logged as ended at its bound", ctx do
      vectors = @vectors |> File.read!() |> Jason.decode!()

      at_bound =
        Enum.find(vectors["replies"], &(&1["type"] == "exited" and &1["memory_exceeded"]))

      {name, spawner} = start_client!(ctx, memory_bytes: 536_870_912)
      handle = start_handle!(name)
      %{"id" => id, "attach" => %{"token" => token}} = next_request(spawner)
      spawn_id = at_bound["spawn_id"]
      reply(spawner, %{v: 1, type: "spawned", id: id, spawn_id: spawn_id, uid: 30_101, pid: 4242})
      relay = attach!(ctx.dir, token)
      assert_receive {RunnerProcess, ^handle, :ready}, 5_000

      log =
        capture_log(fn ->
          reply(spawner, at_bound)
          assert_receive {RunnerProcess, ^handle, {:exited, {:signal, "SIGKILL"}}}, 5_000
          :gen_tcp.close(relay)
          assert_receive {RunnerProcess, ^handle, :closed}, 5_000
        end)

      assert log =~ "runner runner_1 was ended at its memory bound of 536870912 bytes"
      assert log =~ "spawn #{spawn_id}, signal SIGKILL"

      reply(spawner, %{v: 1, type: "released", spawn_id: spawn_id})
      assert_receive {RunnerProcess, ^handle, :released}, 5_000
    end

    test "an end that is not at the bound is logged as nothing of the kind", ctx do
      {name, spawner} = start_client!(ctx)
      handle = start_handle!(name)
      %{"id" => id} = next_request(spawner)
      spawn_id = spawn_id(7)
      reply(spawner, %{v: 1, type: "spawned", id: id, spawn_id: spawn_id, uid: 30_101, pid: 4242})

      log =
        capture_log(fn ->
          reply(spawner, %{
            v: 1,
            type: "exited",
            spawn_id: spawn_id,
            code: nil,
            signal: "SIGKILL",
            memory_exceeded: false
          })

          assert_receive {RunnerProcess, ^handle, {:exited, {:signal, "SIGKILL"}}}, 5_000
        end)

      refute log =~ "memory bound"
    end

    # The pool spawns through the client registered under the keeper's own
    # name, as the service tree starts it.
    test "is tainted, released and never handed out again by the pool", ctx do
      {_name, spawner} = start_client!(ctx, name: Spawn, memory_bytes: 268_435_456)
      supervisor = :"memory_pool_runners_#{ctx.unique}"
      start_supervised!({DynamicSupervisor, name: supervisor, strategy: :one_for_one})
      {:ok, defaults} = Opus.Settings.pool([], %{})

      pool =
        start_supervised!(
          {RunnerPool,
           name: :"memory_pool_#{ctx.unique}",
           settings: %{defaults | pool_size: 1},
           keeper: Spawn,
           supervisor: supervisor,
           command: %{argv: ["/app/bin/opus", "start"], env: %{}}}
        )

      :ok =
        RunnerPool.serve(
          pool,
          %{service_id: "wrk_local", boot: "boot_memory", host_url: "http://127.0.0.1:9"},
          self()
        )

      {first, rest} = request(spawner)
      assert %{"memory_bytes" => 268_435_456, "id" => id, "attach" => %{"token" => token}} = first
      assert rest == ""
      spawn_id = spawn_id(1)
      reply(spawner, %{v: 1, type: "spawned", id: id, spawn_id: spawn_id, uid: 30_101, pid: 4242})
      relay = attach!(ctx.dir, token)
      wait_until(fn -> RunnerPool.status(pool).runners.fresh == 1 end)

      {:ok, pid, runner} = RunnerPool.take(pool, "ath_memory", "exec_memory")
      # The pool refills behind the take: a second runner, under the same bound.
      assert %{"memory_bytes" => 268_435_456, "id" => refill_id} = next_request(spawner)
      assert RunnerPool.status(pool).runners.busy == 1

      capture_log(fn ->
        reply(spawner, %{
          v: 1,
          type: "exited",
          spawn_id: spawn_id,
          code: nil,
          signal: "SIGKILL",
          memory_exceeded: true
        })

        assert_receive {RunnerPool, ^pid, {:gone, _reason}}, 5_000
      end)

      # Tainted and released through the keeper at once, with no grace.
      assert %{"type" => "release", "spawn_id" => ^spawn_id, "grace_ms" => 0} =
               next_request(spawner)

      assert RunnerPool.status(pool).runners.tainted == 1
      :gen_tcp.close(relay)
      reply(spawner, %{v: 1, type: "released", spawn_id: spawn_id})
      wait_until(fn -> RunnerPool.status(pool).runners.tainted == 0 end)
      refute Enum.any?(RunnerPool.runners(pool), &(&1.id == runner))

      # The athanor's next subtree gets another runner, never this one.
      reply(spawner, %{
        v: 1,
        type: "spawned",
        id: refill_id,
        spawn_id: spawn_id(2),
        uid: 30_102,
        pid: 4243
      })

      assert {:ok, other, other_runner} = RunnerPool.take(pool, "ath_memory", "exec_next")
      assert other != pid and other_runner != runner
    end
  end

  describe "a spawn the keeper cannot bound" do
    @tag skip: @no_vectors
    test "is refused typed, logged once naming the option, and never asked again without its bound",
         ctx do
      vectors = @vectors |> File.read!() |> Jason.decode!()

      assert %{"code" => "memory_unavailable"} =
               Enum.find(vectors["replies"], &(&1["code"] == "memory_unavailable"))

      {name, spawner} = start_client!(ctx)

      log =
        capture_log(fn ->
          first = start_handle!(name, "runner_1")
          %{"id" => id} = next_request(spawner)
          reply(spawner, %{v: 1, type: "error", id: id, code: "memory_unavailable"})
          assert_receive {RunnerProcess, ^first, {:refused, :memory_unavailable}}, 5_000

          second = start_handle!(name, "runner_2")
          %{"id" => id, "memory_bytes" => @default} = next_request(spawner)
          reply(spawner, %{v: 1, type: "error", id: id, code: "memory_unavailable"})
          assert_receive {RunnerProcess, ^second, {:refused, :memory_unavailable}}, 5_000
        end)

      assert [_once] = Regex.scan(~r/writable-cgroups=true/, log)
      assert log =~ "runner runner_1 was not started"

      # A refused runner is not retried by the client, bounded or not.
      assert silent?(spawner, 200)

      # Another refusal is logged again once a runner was spawned since.
      third = start_handle!(name, "runner_3")
      %{"id" => id} = next_request(spawner)
      reply(spawner, %{v: 1, type: "spawned", id: id, spawn_id: spawn_id(3), uid: 30_101, pid: 1})
      wait_until(fn -> RunnerProcess.info(third).os_pid == 1 end)

      log =
        capture_log(fn ->
          fourth = start_handle!(name, "runner_4")
          %{"id" => id} = next_request(spawner)
          reply(spawner, %{v: 1, type: "error", id: id, code: "memory_unavailable"})
          assert_receive {RunnerProcess, ^fourth, {:refused, :memory_unavailable}}, 5_000
        end)

      assert log =~ "runner runner_4 was not started"
    end

    test "is told apart from a keeper that is merely full", ctx do
      {name, spawner} = start_client!(ctx)
      handle = start_handle!(name)
      %{"id" => id} = next_request(spawner)

      log =
        capture_log(fn ->
          reply(spawner, %{v: 1, type: "error", id: id, code: "capacity"})
          assert_receive {RunnerProcess, ^handle, {:refused, "capacity"}}, 5_000
        end)

      refute log =~ "writable-cgroups"
    end
  end
end
