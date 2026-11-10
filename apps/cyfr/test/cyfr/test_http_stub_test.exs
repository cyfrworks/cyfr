# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.HTTPStubTest do
  @moduledoc """
  A stub's server ends with the check `Cyfr.Test.HTTPStub.open/0`
  registers, even when ExUnit kills that check past the test's timeout
  while a request is still in flight: the server, the handler it runs and
  its listener all go.
  """
  use ExUnit.Case, async: true

  import Prima.Test.Wait, only: [wait_until: 2]

  alias Cyfr.Test.HTTPStub

  test "a check killed with a request in flight stops the server, its handler and its listener" do
    stub = HTTPStub.open()
    test = self()

    HTTPStub.stub(stub, "GET", "/held", fn conn ->
      send(test, {:held, self()})

      receive do
        :release -> Plug.Conn.resp(conn, 200, "ok")
      end
    end)

    spawn(fn -> Req.get("http://127.0.0.1:#{stub.port}/held", retry: false) end)
    assert_receive {:held, handler}, 5_000

    server_ref = Process.monitor(stub.server)
    handler_ref = Process.monitor(handler)

    # The check as ExUnit runs it, from a process of its own, which it
    # kills when the check outlives the test's timeout.
    check = spawn(fn -> HTTPStub.verify!(stub.server) end)
    # Once the check waits for its answer, its call is in the server's
    # mailbox, so the server has taken it by the time it answers a call
    # sent after.
    wait_until(fn -> Process.info(check, :status) == {:status, :waiting} end, 5_000)
    %{listener: server} = :sys.get_state(stub.server)
    listener = ThousandIsland.Server.listener_pid(server)
    {listening, _span} = ThousandIsland.Listener.acceptor_info(listener, 1)
    assert :inet.sockname(listening) == {:ok, {{127, 0, 0, 1}, stub.port}}

    Process.exit(check, :kill)

    assert_receive {:DOWN, ^server_ref, :process, _, _}, 5_000
    assert_receive {:DOWN, ^handler_ref, :process, _, _}, 5_000
    # Another server may hold the freed port; inspect the socket the stub owned.
    assert {:error, _closed} = :inet.sockname(listening)

    # The check `open/0` registered would find the server gone; this
    # replaces it under the same name.
    on_exit({HTTPStub, stub.server}, fn -> :ok end)
  end
end
