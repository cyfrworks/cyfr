# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.ScriptedBuilder do
  @moduledoc """
  A Locus builds service whose builds answer from a script instead of
  running a toolchain, as `Cyfr.Test.ScriptedWorker` stands in for a
  worker service. Test-only; users are `async: false`, since the script is
  one named process and the builds service is application configuration.

  Everything but the build is the contract's. It is served by Bandit on a
  loopback port of the system's choosing (`url/0`), and a request is
  answered as `Cyfr.BuilderProtocol` says a builds service answers it: a
  `POST` to a route of the protocol, the `x-cyfr-auth` header verified
  with the request key before the body is read (`401` `unauthorized` with
  the refusal, and `replayed` for a nonce seen before), the body read up
  to `max_request_bytes/0` and checked against the hash the header named,
  then read strictly (`409` `protocol_mismatch`, `400` `malformed`).
  `health` answers without authentication. Its service key, the request
  key it verifies with and the lines it answers by default are the vectors
  of `tests/fixtures/locus_builds.json` (`fixture/0`): the request key is
  the vector's own, not one derived here, so a client that derived another
  is refused.

  `start!/1`, from a test's `setup`, starts it for the test and points
  this server's builds service at it (`config :cyfr, :locus_builds_url`
  and `:locus_builds_key`, restored when the test ends); the builds run
  under the application's `Compendium.Builds.TaskSupervisor`.
  `client_key:` configures this server with another key than the
  service's.

  ## The script

  `script/1` queues answers, one per build request, consumed in order; a
  build request with nothing queued is refused `unavailable`. An answer is:

  - `{:refuse, refusal}` or `{:refuse, refusal, diagnostics}` — a refusal
    before the stream, the one line of the body at its class's status.
  - `{:respond, status, body}` — any status and body: another server's
    page, a line of the fixture.
  - `{:stream, steps}` — a `200` whose lines are the steps, in order,
    after which the answer ends:
      - `{:progress, stage, message}`, `{:result, result}` and
        `{:refusal, refusal, diagnostics}` — the protocol's lines
      - `{:line, text}` — `text` and a newline, whatever it is
      - `{:bytes, iodata}` — bytes as they are, no newline
      - `{:repeat, binary, times}` — the same bytes again and again,
        stopping early once the client has gone
      - `{:hold, pid}` — send `pid` `{:scripted_builder, :holding, handler}`
        and wait: `:continue` sent to `handler` goes on to the next step;
        the client closing its connection sends `pid`
        `{:scripted_builder, :disconnected}` and ends the answer
      - `:drop` — close the connection where it stands, the body unended

  `requests/0` answers the build requests it verified and read, in order,
  and `bodies/0` the bytes each arrived as.
  """

  use GenServer

  alias Cyfr.BuilderProtocol

  @fixture_path Path.expand("../../../../tests/fixtures/locus_builds.json", __DIR__)
  @external_resource @fixture_path
  @fixture @fixture_path |> File.read!() |> Jason.decode!()
  @supervisor Compendium.Builds.TaskSupervisor

  @doc "The protocol's vector file, decoded."
  @spec fixture() :: map()
  def fixture, do: @fixture

  @doc "The service key the vectors are signed under, its 32 bytes."
  @spec key() :: <<_::256>>
  def key do
    {:ok, key} = BuilderProtocol.decode_key(@fixture["key_hex"])
    key
  end

  # The key requests are verified with, as the vectors spell it.
  defp request_key, do: Base.decode16!(@fixture["request_key_hex"], case: :lower)

  @doc "Start the builder for the calling test and point this server's builds at it."
  @spec start!(keyword()) :: pid()
  def start!(opts \\ []) do
    pid = ExUnit.Callbacks.start_supervised!({__MODULE__, opts})
    configure!(url(), Keyword.get(opts, :client_key, key()))
    pid
  end

  @doc """
  Point this server's builds service at `url` under `key` (either may be
  nil, which disables builds) until the calling test ends.
  """
  @spec configure!(String.t() | nil, binary() | nil) :: :ok
  def configure!(url, key) do
    previous = for name <- [:locus_builds_url, :locus_builds_key], do: {name, get(name)}

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, fn {name, value} -> put(name, value) end)
    end)

    put(:locus_builds_url, url)
    put(:locus_builds_key, key)
  end

  @doc """
  Wait until no task of `Compendium.Builds` is running: a started build,
  the process watching it, a request, a registration. A test whose build
  succeeded calls it before it ends, so the registration it started
  finishes with the database and the tree it was started under.
  """
  @spec await_builds(non_neg_integer()) :: :ok
  def await_builds(timeout \\ 10_000) do
    Cyfr.Test.Wait.wait_until(
      fn -> Task.Supervisor.children(@supervisor) == [] end,
      timeout,
      "the builds' tasks to finish"
    )
  end

  defp get(name), do: Application.get_env(:cyfr, name)
  defp put(name, nil), do: Application.delete_env(:cyfr, name)
  defp put(name, value), do: Application.put_env(:cyfr, name, value)

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The base URL the builder answers on."
  @spec url() :: String.t()
  def url, do: GenServer.call(__MODULE__, :url)

  @doc "Queue `answers`, one per build request to come."
  @spec script([term()]) :: :ok
  def script(answers) when is_list(answers), do: GenServer.call(__MODULE__, {:script, answers})

  @doc "The build requests verified and read so far, in order."
  @spec requests() :: [BuilderProtocol.request()]
  def requests, do: GenServer.call(__MODULE__, :requests)

  @doc "The body each of `requests/0` arrived as, in order."
  @spec bodies() :: [binary()]
  def bodies, do: GenServer.call(__MODULE__, :bodies)

  @doc "The health line's content answered from now on (the fixture's by default)."
  @spec health(BuilderProtocol.health() | {:line, String.t()}) :: :ok
  def health(health), do: GenServer.call(__MODULE__, {:health, health})

  @impl true
  def init(_opts) do
    {:ok, listener} =
      Bandit.start_link(
        plug: {__MODULE__.Listener, server: self(), request_key: request_key()},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)

    {:ok,
     %{
       url: "http://127.0.0.1:#{port}",
       script: [],
       requests: [],
       nonces: MapSet.new(),
       health: {:line, @fixture["lines"]["health"]["body"]}
     }}
  end

  @impl true
  def handle_call(:url, _from, state), do: {:reply, state.url, state}

  def handle_call(:requests, _from, state),
    do: {:reply, state.requests |> Enum.reverse() |> Enum.map(&elem(&1, 0)), state}

  def handle_call(:bodies, _from, state),
    do: {:reply, state.requests |> Enum.reverse() |> Enum.map(&elem(&1, 1)), state}

  def handle_call({:script, answers}, _from, state),
    do: {:reply, :ok, %{state | script: state.script ++ answers}}

  def handle_call({:health, health}, _from, state), do: {:reply, :ok, %{state | health: health}}
  def handle_call(:health, _from, state), do: {:reply, state.health, state}

  def handle_call({:nonce, nonce}, _from, state) do
    if MapSet.member?(state.nonces, nonce),
      do: {:reply, :replayed, state},
      else: {:reply, :ok, %{state | nonces: MapSet.put(state.nonces, nonce)}}
  end

  def handle_call({:build, request, body}, _from, state) do
    state = %{state | requests: [{request, body} | state.requests]}

    case state.script do
      [answer | rest] ->
        {:reply, answer, %{state | script: rest}}

      [] ->
        {:reply, {:refuse, {:unavailable, "the scripted builder has no answer scripted"}}, state}
    end
  end

  defmodule Listener do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    alias Cyfr.BuilderProtocol

    @impl Plug
    def init(opts), do: Map.new(opts)

    @impl Plug
    def call(%Plug.Conn{method: "POST"} = conn, opts) do
      case BuilderProtocol.operation(conn.request_path) do
        {:ok, :health} -> health(conn, opts)
        {:ok, :build} -> build(conn, opts)
        :error -> send_resp(conn, 404, "")
      end
    end

    def call(conn, _opts), do: send_resp(conn, 404, "")

    defp health(conn, opts) do
      with {:ok, body, conn} <- bounded_body(conn),
           :ok <- BuilderProtocol.read_health_request(body) do
        case GenServer.call(opts.server, :health) do
          {:line, line} ->
            send_resp(conn, 200, line <> "\n")

          health ->
            {:ok, line} = BuilderProtocol.encode_health(health)
            send_resp(conn, 200, line <> "\n")
        end
      else
        {:error, conn, error} -> refuse(conn, BuilderProtocol.refusal_for(error), [])
        {:error, error} -> refuse(conn, BuilderProtocol.refusal_for(error), [])
      end
    end

    # The header is verified before the body is read, so a caller without
    # the key is refused without the listener reading what it sent.
    defp build(conn, opts) do
      now = System.system_time(:millisecond)

      with {:ok, auth, body_hash} <-
             BuilderProtocol.verify_request_header(opts.request_key, header(conn), now),
           :ok <- GenServer.call(opts.server, {:nonce, auth.nonce}) do
        build(conn, opts, body_hash)
      else
        :replayed -> refuse(conn, {:unauthorized, :replayed}, [])
        {:error, refusal} -> refuse(conn, {:unauthorized, refusal}, [])
      end
    end

    defp build(conn, opts, body_hash) do
      with {:ok, body, conn} <- bounded_body(conn),
           {:body, :ok} <- {:body, BuilderProtocol.verify_body(body_hash, body)},
           {:ok, request} <- BuilderProtocol.read_request(body) do
        answer(conn, GenServer.call(opts.server, {:build, request, body}))
      else
        {:body, {:error, :bad_mac}} -> refuse(conn, {:unauthorized, :bad_mac}, [])
        {:error, conn, error} -> refuse(conn, BuilderProtocol.refusal_for(error), [])
        {:error, error} -> refuse(conn, BuilderProtocol.refusal_for(error), [])
      end
    end

    defp header(conn) do
      case get_req_header(conn, BuilderProtocol.auth_header()) do
        [header] -> header
        _none_or_many -> nil
      end
    end

    defp bounded_body(conn) do
      max = BuilderProtocol.max_request_bytes()

      case read_body(conn, length: max, read_length: max) do
        {:ok, body, conn} -> {:ok, body, conn}
        {:more, _partial, conn} -> {:error, conn, {:too_large, :request, max + 1, max}}
        {:error, _reason} -> {:error, conn, :not_json}
      end
    end

    defp refuse(conn, refusal, diagnostics) do
      {:ok, line} = BuilderProtocol.encode_refusal(refusal, diagnostics)

      conn
      |> put_resp_content_type("application/x-ndjson")
      |> send_resp(BuilderProtocol.status(refusal), line <> "\n")
    end

    defp answer(conn, {:refuse, refusal}), do: refuse(conn, refusal, [])
    defp answer(conn, {:refuse, refusal, diagnostics}), do: refuse(conn, refusal, diagnostics)
    defp answer(conn, {:respond, status, body}), do: send_resp(conn, status, body)

    defp answer(conn, {:stream, steps}) do
      conn = conn |> put_resp_content_type("application/x-ndjson") |> send_chunked(200)

      Enum.reduce_while(steps, conn, fn step, conn ->
        case step(conn, step) do
          {:ok, conn} -> {:cont, conn}
          {:error, _closed} -> {:halt, conn}
        end
      end)
    end

    defp step(conn, {:progress, stage, message}) do
      {:ok, line} = BuilderProtocol.encode_progress(stage, message)
      chunk(conn, line <> "\n")
    end

    defp step(conn, {:result, result}) do
      {:ok, line} = BuilderProtocol.encode_result(result)
      chunk(conn, line <> "\n")
    end

    defp step(conn, {:refusal, refusal, diagnostics}) do
      {:ok, line} = BuilderProtocol.encode_refusal(refusal, diagnostics)
      chunk(conn, line <> "\n")
    end

    defp step(conn, {:line, text}), do: chunk(conn, [text, "\n"])
    defp step(conn, {:bytes, bytes}), do: chunk(conn, bytes)

    defp step(conn, {:repeat, bytes, times}) do
      Enum.reduce_while(1..times, {:ok, conn}, fn _n, {:ok, conn} ->
        case chunk(conn, bytes) do
          {:ok, conn} -> {:cont, {:ok, conn}}
          {:error, _closed} = closed -> {:halt, closed}
        end
      end)
    end

    # The request has been read whole, so the socket's next event is the
    # client closing it: active-once turns that into a message this
    # process waits for beside the test's `:continue`.
    defp step(conn, {:hold, pid}) do
      socket = socket(conn)
      :ok = ThousandIsland.Socket.setopts(socket, active: :once)
      send(pid, {:scripted_builder, :holding, self()})

      receive do
        :continue ->
          :ok = ThousandIsland.Socket.setopts(socket, active: false)
          {:ok, conn}

        {:tcp_closed, _port} ->
          send(pid, {:scripted_builder, :disconnected})
          {:error, :closed}

        {:tcp_error, _port, _reason} ->
          send(pid, {:scripted_builder, :disconnected})
          {:error, :closed}
      end
    end

    # The socket is closed under the chunked body, so the client reads an
    # answer cut short; what Bandit then fails to write is its own
    # client-closure case.
    defp step(conn, :drop) do
      ThousandIsland.Socket.close(socket(conn))
      {:error, :closed}
    end

    defp socket(%Plug.Conn{adapter: {Bandit.Adapter, %{transport: %{socket: socket}}}}),
      do: socket
  end
end
