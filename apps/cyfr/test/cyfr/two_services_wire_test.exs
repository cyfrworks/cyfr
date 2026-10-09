# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.TwoServices.WireTest do
  @moduledoc """
  The test wire's settle contract: a reader that finds the wire settled
  finds recorded every call its listener acted on.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Cyfr.Test.TwoServices.Wire

  defmodule Listener do
    @moduledoc false
    # Tells the test it has the request, and answers when the test says so.
    @behaviour Plug

    @impl true
    def init(test), do: test

    @impl true
    def call(conn, test) do
      send(test, {:acted, self()})

      receive do
        :answer -> Plug.Conn.send_resp(conn, 200, "answered")
      end
    end
  end

  setup do
    listener =
      start_supervised!(
        {Bandit, plug: {Listener, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    {:ok, wire: Wire.start!("http://127.0.0.1:#{port}")}
  end

  # A request across the wire, from a process of its own; the hook the test
  # set holds the call between its answer and its record.
  defp request!(wire) do
    test = self()

    Wire.after_answer(wire, fn call ->
      send(test, {:answered, self(), call})

      receive do
        :go -> :ok
      end
    end)

    Task.async(fn ->
      Req.post(wire.url <> "/call", body: "x", retry: false, decode_body: false)
    end)
  end

  defp answer! do
    assert_receive {:acted, listener}, 5_000
    send(listener, :answer)
    assert_receive {:answered, conn, %{route: "/call"}}, 5_000
    conn
  end

  # Bandit reports a request whose plug raised from the request's own
  # process, before it answers 500 and closes the connection, which ends
  # that process. Each such request of `wire` is held there, alive past its
  # failure, until the test lets it go; the test hears `{:failed, conn}`.
  defp hold_failed!(wire) do
    id = {__MODULE__, make_ref()}
    config = %{agent: wire.agent, test: self()}

    :ok =
      :telemetry.attach(id, [:bandit, :request, :exception], &__MODULE__.hold_failed/4, config)

    on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def hold_failed(_event, _measurements, %{plug: {Wire, %{agent: agent}}}, %{
        agent: agent,
        test: test
      }) do
    send(test, {:failed, self()})

    receive do
      :go -> :ok
    end
  end

  def hold_failed(_event, _measurements, _metadata, _config), do: :ok

  test "a call its listener answered is crossing until the wire records it", %{wire: wire} do
    caller = request!(wire)
    assert_receive {:acted, listener}, 5_000
    refute Wire.settled?(wire)

    send(listener, :answer)
    assert_receive {:answered, conn, %{route: "/call"}}, 5_000
    refute Wire.settled?(wire)
    assert Wire.calls(wire) == []

    send(conn, :go)
    assert {:ok, %{status: 200, body: "answered"}} = Task.await(caller)
    assert Wire.settled?(wire)
    assert [%{route: "/call", action: :forward}] = Wire.calls(wire)
  end

  test "a request that fails after its listener acted leaves nothing crossing", %{wire: wire} do
    Wire.after_answer(wire, fn _call -> raise "the hook failed" end)
    hold_failed!(wire)

    caller =
      Task.async(fn ->
        Req.post(wire.url <> "/call", body: "x", retry: false, decode_body: false)
      end)

    capture_log(fn ->
      assert_receive {:acted, listener}, 5_000
      send(listener, :answer)

      # The failed request's process is alive, so only the wire's own
      # clearing of its mark leaves the wire settled.
      assert_receive {:failed, conn}, 5_000
      assert Process.alive?(conn)
      assert Wire.settled?(wire)
      assert Wire.calls(wire) == []

      send(conn, :go)
      assert {:ok, %{status: 500}} = Task.await(caller)
    end)
  end

  test "a request process killed while its call crosses does not keep the wire unsettled", %{
    wire: wire
  } do
    caller = request!(wire)
    conn = answer!()
    refute Wire.settled?(wire)

    ref = Process.monitor(conn)
    Process.exit(conn, :kill)
    assert_receive {:DOWN, ^ref, :process, ^conn, :killed}, 5_000

    assert Wire.settled?(wire)
    assert Wire.calls(wire) == []
    assert {:error, _closed} = Task.await(caller)
  end
end
