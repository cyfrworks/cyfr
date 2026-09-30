# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.GracefulStopTest do
  @moduledoc """
  A graceful stop refuses before it drains: `Cyfr.Application.prep_stop/1`
  marks the LiveView socket draining and closes the endpoint's listening
  ports before the supervision tree stops. A new connection, a tab the
  LiveView drainer tells to reconnect included, is refused by the member
  that is stopping, and so is a LiveView connect over either transport on
  a connection already open, while a request already open finishes within
  the drain. The suspension fails safe: a server that cannot be suspended
  is logged and one that does not answer holds the stop no longer than its
  deadline.

  Driven against socket servers this test starts on port 0, and against
  the running endpoint's `/live` socket through `Phoenix.ConnTest`; the
  running application, whose endpoint serves no listener here, is never
  stopped. The drain mark is a node-wide persistent term, erased after
  every test.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias Cyfr.Application, as: App
  alias CyfrWeb.LiveSocket

  @endpoint CyfrWeb.Endpoint

  # `CyfrWeb.LiveSocket`'s drain mark: only the application's start clears
  # it, so each test clears it itself.
  setup do
    on_exit(fn -> LiveSocket.undrain() end)
  end

  defmodule HoldPlug do
    @moduledoc false
    # Holds each request open: it tells the test which process holds it,
    # then answers once the test releases it.
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(test), do: test

    @impl true
    def call(conn, test) do
      send(test, {:held, self()})

      receive do
        :release -> send_resp(conn, 200, "finished")
      after
        10_000 -> send_resp(conn, 504, "never released")
      end
    end
  end

  defmodule Endpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :cyfr

    socket "/live", CyfrWeb.LiveSocket, websocket: true, longpoll: true

    plug :answer

    def answer(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "ok")
  end

  @loopback {127, 0, 0, 1}

  defp connect(port), do: :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2_000)

  defp port(server) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  # Everything the server writes to `socket` until it closes the
  # connection, which it does once the answer is written.
  defp read_until_closed(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> read_until_closed(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end

  # The connection process `handler` has been told to stop: the drain has
  # begun, and it waits for the request the process holds.
  defp draining?(handler) do
    {:messages, messages} = Process.info(handler, :messages)
    Enum.any?(messages, &match?({:EXIT, _supervisor, :shutdown}, &1))
  end

  # One HTTP/1.1 response read off `socket`, which stays open: its status
  # line and the body its content-length names.
  defp recv_response(socket, acc \\ "") do
    with [head, body] <- String.split(acc, "\r\n\r\n", parts: 2),
         [_, length] <- Regex.run(~r/\r\ncontent-length: *(\d+)/i, head),
         length = String.to_integer(length),
         true <- byte_size(body) >= length do
      {head |> String.split("\r\n") |> hd(), binary_part(body, 0, length)}
    else
      _ ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        recv_response(socket, acc <> data)
    end
  end

  # The LiveView client's two ways in: a long-poll session's first GET,
  # and a WebSocket upgrade. `vsn` is the protocol the client speaks. The
  # long-poll transport answers every poll 200 and puts its own status in
  # the JSON body: 410 with a token opens a session, 403 refuses it.
  @longpoll "GET /live/longpoll?vsn=2.0.0 HTTP/1.1\r\nhost: localhost\r\n\r\n"
  @websocket "GET /live/websocket?vsn=2.0.0 HTTP/1.1\r\nhost: localhost\r\n" <>
               "connection: upgrade\r\nupgrade: websocket\r\n" <>
               "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\nsec-websocket-version: 13\r\n\r\n"

  defp websocket_upgrade do
    # `Plug.Conn` keeps the host out of the headers; the upgrade's
    # validation reads it from them, as a real request carries it.
    conn = build_conn()

    %{conn | req_headers: [{"host", "localhost"} | conn.req_headers]}
    |> put_req_header("connection", "upgrade")
    |> put_req_header("upgrade", "websocket")
    |> put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
    |> put_req_header("sec-websocket-version", "13")
    |> get("/live/websocket?vsn=2.0.0")
  end

  defp longpoll_session, do: get(build_conn(), "/live/longpoll?vsn=2.0.0")

  # The long-poll sessions running on this node: an admitted long-poll
  # connect starts one, which the test stops rather than leave it to its
  # idle timeout.
  defp longpoll_sessions do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Phoenix.Transports.LongPoll.Supervisor),
        is_pid(pid),
        do: pid
  end

  defp stop_sessions_since(before) do
    for pid <- longpoll_sessions() -- before,
        do: DynamicSupervisor.terminate_child(Phoenix.Transports.LongPoll.Supervisor, pid)
  end

  defp await(condition, deadline_ms \\ 5_000) do
    cond do
      condition.() ->
        :ok

      deadline_ms <= 0 ->
        flunk("the condition did not hold in time")

      true ->
        Process.sleep(10)
        await(condition, deadline_ms - 10)
    end
  end

  describe "a suspended server" do
    setup do
      server =
        start_supervised!(
          Supervisor.child_spec(
            {Bandit,
             plug: {HoldPlug, self()},
             scheme: :http,
             ip: @loopback,
             port: 0,
             startup_log: false,
             thousand_island_options: [shutdown_timeout: 5_000]},
            restart: :temporary
          )
        )

      %{server: server, port: port(server)}
    end

    test "refuses a new connection at once, and a request already open finishes in the drain",
         %{server: server, port: port} do
      {:ok, open} = connect(port)
      :ok = :gen_tcp.send(open, "GET / HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n")
      assert_receive {:held, handler}, 5_000

      assert App.suspend_server(server) == :ok

      # A tab told to reconnect opens a new connection, as any client does:
      # this member refuses it, so it reaches another member or the
      # restarted server.
      assert {:error, :econnrefused} = connect(port)

      stopping = Task.async(fn -> ThousandIsland.stop(server, 15_000) end)
      await(fn -> draining?(handler) end)

      # Still refused while the stop drains.
      assert {:error, :econnrefused} = connect(port)

      send(handler, :release)
      response = read_until_closed(open)
      assert response =~ "HTTP/1.1 200"
      assert response =~ "finished"
      assert Task.await(stopping, 15_000) == :ok
    end

    test "a server that is gone is logged and answered :error, never raised", %{server: server} do
      :ok = ThousandIsland.stop(server)

      log = capture_log(fn -> assert App.suspend_server(server) == :error end)
      assert log =~ "could not stop accepting"
    end
  end

  describe "an endpoint's servers" do
    setup do
      Application.put_env(:cyfr, Endpoint,
        adapter: Bandit.PhoenixAdapter,
        http: [ip: @loopback, port: 0, startup_log: false],
        secret_key_base: String.duplicate("graceful-stop-", 5),
        pubsub_server: Cyfr.PubSub,
        server: true
      )

      on_exit(fn -> Application.delete_env(:cyfr, Endpoint) end)
    end

    test "are found by the lookup, and suspending the endpoint refuses a new connection" do
      start_supervised!(Endpoint)

      assert [server] = App.endpoint_servers(Endpoint)
      port = port(server)

      {:ok, probe} = connect(port)
      :ok = :gen_tcp.close(probe)

      assert App.suspend_endpoint(Endpoint) == :ok
      assert {:error, :econnrefused} = connect(port)
    end

    test "refuse a LiveView connect over a connection already open once the node drains" do
      start_supervised!(Endpoint)
      [server] = App.endpoint_servers(Endpoint)
      port = port(server)
      sessions = longpoll_sessions()
      on_exit(fn -> stop_sessions_since(sessions) end)

      # A keep-alive connection, open before the stop, that the LiveView
      # client could fall back to long polling over.
      {:ok, open} = connect(port)
      :ok = :gen_tcp.send(open, @longpoll)
      assert {"HTTP/1.1 200 OK", body} = recv_response(open)
      assert %{"status" => 410, "token" => _} = Jason.decode!(body)

      # The stop's first two steps, in `prep_stop/1`'s order.
      :ok = LiveSocket.drain()
      assert App.suspend_endpoint(Endpoint) == :ok
      assert {:error, :econnrefused} = connect(port)

      :ok = :gen_tcp.send(open, @longpoll)
      assert {"HTTP/1.1 200 OK", body} = recv_response(open)
      assert Jason.decode!(body) == %{"status" => 403}

      :ok = :gen_tcp.send(open, @websocket)
      assert {"HTTP/1.1 403 Forbidden", ""} = recv_response(open)
    end
  end

  describe "the LiveView socket" do
    setup do
      sessions = longpoll_sessions()
      on_exit(fn -> stop_sessions_since(sessions) end)
    end

    test "admits a connect over either transport while the node is not draining" do
      refute LiveSocket.draining?()

      conn = websocket_upgrade()
      assert conn.state == :upgraded
      assert_received {_ref, :upgrade, {:websocket, {CyfrWeb.LiveSocket, _state, _opts}}}

      conn = longpoll_session()
      assert conn.status == 200
      assert %{"status" => 410, "token" => _} = Jason.decode!(conn.resp_body)
    end

    test "is served again once the drain mark is cleared, as the application's start clears it" do
      :ok = LiveSocket.drain()
      assert LiveSocket.draining?()
      :ok = LiveSocket.undrain()
      refute LiveSocket.draining?()
      :ok = LiveSocket.undrain()
    end

    test "refuses a connect over either transport once the node drains" do
      :ok = LiveSocket.drain()
      assert LiveSocket.draining?()

      conn = websocket_upgrade()
      assert conn.state == :sent
      assert conn.status == 403
      refute_received {_ref, :upgrade, _}

      sessions = longpoll_sessions()
      conn = longpoll_session()
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"status" => 403}
      assert longpoll_sessions() -- sessions == []
    end
  end

  describe "the running application's endpoint" do
    test "serves no listener under test, so the lookup answers nothing and prep_stop leaves it be" do
      assert App.endpoint_servers() == []
      refute LiveSocket.draining?()

      endpoint = Process.whereis(CyfrWeb.Endpoint)
      tree = Process.whereis(Cyfr.Supervisor)

      assert App.prep_stop(:state) == :state

      # The drain is marked whether or not there is a listener to close.
      assert LiveSocket.draining?()
      assert is_pid(endpoint) and Process.alive?(endpoint)
      assert is_pid(tree) and Process.alive?(tree)
      assert Process.whereis(CyfrWeb.Endpoint) == endpoint
    end
  end

  describe "the suspension fails safe" do
    test "an endpoint that is not running has nothing to suspend" do
      name = Module.concat(__MODULE__, NotRunning)

      assert App.endpoint_servers(name) == []
      assert App.suspend_endpoint(name) == :ok
    end

    test "a server the endpoint serves that cannot be suspended is logged and answered :error" do
      name = Module.concat(__MODULE__, Unsuspendable)

      # The shape the Phoenix adapter builds, `{endpoint, scheme}`, over a
      # supervisor that runs no acceptors.
      server = %{
        id: {name, :http},
        start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]},
        type: :supervisor
      }

      start_supervised!(%{
        id: name,
        start: {Supervisor, :start_link, [[server], [strategy: :one_for_one, name: name]]},
        type: :supervisor
      })

      log = capture_log(fn -> assert App.suspend_endpoint(name) == :error end)
      assert log =~ "could not stop accepting"
    end

    test "an endpoint that does not answer holds the stop no longer than the deadline" do
      name = Module.concat(__MODULE__, Silent)

      silent =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      Process.register(silent, name)
      on_exit(fn -> send(silent, :stop) end)

      log =
        capture_log(fn ->
          {micros, answer} = :timer.tc(fn -> App.suspend_endpoint(name, 100) end)
          assert answer == :error
          assert micros < 2_000_000
        end)

      assert log =~ "did not stop accepting within 100 ms"

      # The lookup reached the endpoint and was cut off there, and the
      # abandoned suspension left nothing in the caller's mailbox.
      assert {:messages, [{:"$gen_call", _from, :which_children}]} =
               Process.info(silent, :messages)

      refute_received {:DOWN, _ref, :process, _pid, _reason}
    end
  end
end
