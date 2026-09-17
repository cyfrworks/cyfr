# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.HostListener do
  @moduledoc """
  The HTTP face of `Cyfr.Execution.Host`: one Bandit listener of its own,
  serving the host routes `Cyfr.WorkerWire` declares, on the bind address
  and port its child spec is given. A worker service's runners post their
  host calls here, and the service posts its runner exit reports; nothing
  else is served.

  Every request is refused as early as its evidence allows, before any
  authorized action and, for anything the header alone decides, before
  the body is read:

    1. the route is a host route and the method is `POST`, else `404`;
    2. this boot holds the control plane (`Cyfr.ControlPlane.owner?/0`),
       else `503`, answered as `Cyfr.Execution.Host` would refuse it;
    3. the `x-cyfr-auth` header is present once and verifies over its
       fields and the body hash it names — a host call under the call key
       of the attempt it names and the current generation
       (`Cyfr.WorkerAuth.verify_host_call_header/4`), a report under the
       dispatch key of the worker service it names
       (`Cyfr.WorkerAuth.verify_report_header/3`) — within the timestamp
       window, else `401`;
    4. for a callback that is not idempotent (`Cyfr.HostAPI.retry/1`), the
       header's nonce has not been presented for its attempt within the
       window before, else `401`;
    5. the body is at most `Cyfr.HostAPI.max_body_bytes/0`, else `413`,
       and is the one the header named (`Cyfr.WorkerAuth.verify_body/2`),
       else `401`;
    6. a host call's body opens as the `:body` of the call the header
       names, under the attempt's seal key derived from the root
       (`Cyfr.WorkerAuth.open_call/4`), else `401`;
    7. the body's `op` is the route's callback, else `400`.

  A host call crosses sealed: its HTTP body is
  `Cyfr.WorkerAuth.seal_call/5` of the `{"op", "args"}` JSON in the
  `:body` direction, the header is computed over those sealed bytes, and
  the answer is the JSON `Cyfr.Execution.Host.call/2` produces sealed in
  the `:answer` direction under the same call. `Host.call/2` reads the
  JSON and verifies its header over it, so the listener hands it the
  opened JSON under the verified fields re-signed over that JSON with the
  attempt's call key, which CYFR derives from the root as `Host` does:
  the fields, timestamp and nonce are the runner's, and `Host` verifies
  the whole call again itself. A report (`runner_exited`) crosses as
  plain JSON under its report header, and its answer is plain.

  Every listener refusal is `{"error": "lost"}` (`Cyfr.WorkerWire.error/2`)
  but the unknown route's `not_found`, the mismatched body's `malformed`
  and an unowned report's `unavailable`; the reason is logged, the header
  and body never. An answer, sealed or plain, is sent as `200` whatever
  it says: a refusal `Host` answers is an answer, not a transport
  failure. This listener's checks are defence in depth, and keep an
  unauthenticated caller from making CYFR read what it sent.

  Nothing here is configured from the application environment: the
  supervisor that starts it names the bind and port (`child_spec/1`), so a
  test binds port 0 and reads what it was given (`port/1`).
  """

  use Plug.Router, copy_opts_to_assign: :host_listener

  require Logger

  alias Cyfr.{HostAPI, WorkerAuth, WorkerWire}
  alias Cyfr.Execution.{Host, Keys}

  plug(:match)
  plug(:dispatch)

  @typedoc "How the listener is started: the address to bind and the port (0 for any free one)."
  @type option :: {:bind, :inet.ip_address()} | {:port, :inet.port_number()}

  @doc """
  The listener's child spec: a supervisor of the nonce memory and the
  Bandit server, bound to `:bind` (default loopback) on `:port` (required).
  """
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    %{id: __MODULE__, start: {__MODULE__.Supervisor, :start_link, [opts]}, type: :supervisor}
  end

  @doc "The port the listener started as `supervisor` is bound to."
  @spec port(pid()) :: :inet.port_number()
  defdelegate port(supervisor), to: __MODULE__.Supervisor

  match _ do
    with "POST" <- conn.method,
         {:ok, callback} <- WorkerWire.host_callback(conn.request_path) do
      serve(conn, callback)
    else
      _ -> refuse(conn, 404, :not_found)
    end
  end

  # ---------------------------------------------------------------------------
  # One request
  # ---------------------------------------------------------------------------

  defp serve(conn, callback) do
    now = System.system_time(:millisecond)

    with :ok <- owned(callback),
         {:ok, header} <- auth_header(conn),
         {:ok, fields, body_hash} <- verify_header(callback, header, now),
         :ok <- fresh_nonce(conn, callback, fields, now),
         {:ok, body, read} <- bounded_body(conn),
         :ok <- verify_body(body_hash, body),
         {:ok, call} <- open(callback, fields, header, body),
         :ok <- names_route(callback, call.json) do
      read
      |> put_resp_content_type("application/json")
      |> send_resp(200, answer(callback, fields, call))
    else
      # A refusal after the body was read answers on the conn that read it.
      {:refused, read, status, name} -> refuse(read, status, name)
      {:refused, status, name} -> refuse(conn, status, name)
    end
  end

  # A boot that does not hold the control plane answers for no attempt;
  # `Host` refuses with the same word, so it is answered before the body
  # is read.
  defp owned(callback) do
    if Cyfr.ControlPlane.owner?() do
      :ok
    else
      Logger.warning(
        "[Cyfr.Execution.HostListener] #{callback} refused: this boot does not hold the " <>
          "control plane"
      )

      {:refused, 503, if(callback == :runner_exited, do: :unavailable, else: :lost)}
    end
  end

  defp auth_header(conn) do
    case get_req_header(conn, WorkerWire.auth_header()) do
      [header] ->
        {:ok, header}

      headers ->
        Logger.warning(
          "[Cyfr.Execution.HostListener] refused: #{length(headers)} " <>
            "#{WorkerWire.auth_header()} headers"
        )

        {:refused, 401, :lost}
    end
  end

  # A report verifies under the dispatch key of the service it names; a
  # host call under the call key of the attempt it names, at the current
  # generation. A generation the control plane cannot answer verifies
  # nothing.
  defp verify_header(:runner_exited, header, now) do
    case WorkerAuth.verify_report_header(Keys.root(), header, now) do
      {:ok, fields, body_hash} -> {:ok, fields, body_hash}
      {:error, reason} -> header_refused(:runner_exited, reason)
    end
  end

  defp verify_header(callback, header, now) do
    with {:ok, generation} <- Keys.generation(),
         {:ok, fields, body_hash} <-
           WorkerAuth.verify_host_call_header(Keys.root(), header, now, generation) do
      {:ok, fields, body_hash}
    else
      {:error, :unavailable} ->
        Logger.warning(
          "[Cyfr.Execution.HostListener] #{callback} refused: the control-plane generation " <>
            "is not known"
        )

        {:refused, 503, :lost}

      {:error, reason} ->
        header_refused(callback, reason)
    end
  end

  defp header_refused(callback, reason) do
    Logger.warning("[Cyfr.Execution.HostListener] #{callback} refused: #{reason}")
    {:refused, 401, :lost}
  end

  # A nonce is remembered per attempt for as long as a header carrying it
  # still verifies. An idempotent callback (and a report, which is one)
  # may be repeated as it is.
  defp fresh_nonce(conn, callback, fields, now) do
    if HostAPI.retry(callback) == :idempotent or
         __MODULE__.Nonces.fresh?(conn.assigns.host_listener.nonces, fields, now) do
      :ok
    else
      Logger.warning(
        "[Cyfr.Execution.HostListener] #{callback} refused: the nonce was presented before"
      )

      {:refused, 401, :lost}
    end
  end

  # The body is read only after the header verified, and only up to the
  # contract's bound: a declared length over it is refused without a read,
  # and a longer one as soon as the bound is passed.
  defp bounded_body(conn) do
    max = HostAPI.max_body_bytes()

    with :ok <- declared_length(conn, max),
         {:ok, body, conn} <- Plug.Conn.read_body(conn, length: max, read_length: max) do
      {:ok, body, conn}
    else
      {:more, _partial, conn} ->
        Logger.warning("[Cyfr.Execution.HostListener] refused: the body exceeds #{max} bytes")
        {:refused, conn, 413, :lost}

      {:error, _reason} ->
        Logger.warning("[Cyfr.Execution.HostListener] refused: the body could not be read")
        {:refused, 400, :lost}

      {:refused, _status, _name} = refused ->
        refused
    end
  end

  defp declared_length(conn, max) do
    with [length] <- get_req_header(conn, "content-length"),
         {declared, ""} when declared > max <- Integer.parse(length) do
      Logger.warning(
        "[Cyfr.Execution.HostListener] refused: the body declares #{declared} bytes, over #{max}"
      )

      {:refused, 413, :lost}
    else
      _ -> :ok
    end
  end

  defp verify_body(body_hash, body) do
    case WorkerAuth.verify_body(body_hash, body) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Cyfr.Execution.HostListener] refused: the body is not the header's: #{reason}"
        )

        {:refused, 401, :lost}
    end
  end

  # A report crosses plain. A host call's body opens under the attempt's
  # seal key as the `:body` of the header's call, and the opened JSON is
  # handed to `Host` under the same verified fields, signed over it with
  # the attempt's call key, since `Host` verifies the header over the body
  # it reads. Both keys derive from the root and the verified fields.
  defp open(:runner_exited, _fields, header, body), do: {:ok, %{header: header, json: body}}

  defp open(callback, fields, _header, body) do
    {:ok, seal_key} = WorkerAuth.attempt_seal_key(Keys.root(), fields)

    case WorkerAuth.open_call(seal_key, :body, fields, body) do
      {:ok, json} ->
        {:ok, call_key} = WorkerAuth.attempt_call_key(Keys.root(), fields)
        {:ok, header} = WorkerAuth.host_call_header(call_key, fields, json)
        {:ok, %{header: header, json: json, seal_key: seal_key}}

      {:error, :unsealable} ->
        Logger.warning(
          "[Cyfr.Execution.HostListener] #{callback} refused: the body does not open as the " <>
            "header's call"
        )

        {:refused, 401, :lost}
    end
  end

  defp answer(:runner_exited, _fields, call), do: Host.runner_exited(call.header, call.json)

  defp answer(_callback, fields, call) do
    {:ok, sealed} =
      WorkerAuth.seal_call(call.seal_key, :answer, fields, Host.call(call.header, call.json))

    sealed
  end

  # The route and the body name the same callback, so a body cannot be
  # posted at another route.
  defp names_route(callback, body) do
    named =
      with {:ok, decoded} <- Jason.decode(body),
           {:ok, named, _args} <- WorkerWire.read_request_body(HostAPI, decoded),
           do: named

    if named == callback do
      :ok
    else
      Logger.warning(
        "[Cyfr.Execution.HostListener] #{callback} refused: the body does not name it"
      )

      {:refused, 400, :malformed}
    end
  end

  defp refuse(conn, status, name) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(WorkerWire.error(name)))
  end

  defmodule Supervisor do
    @moduledoc false
    # One listener: the nonce table, owned here so a request that crashes
    # forgets nothing, its sweeper, and the Bandit server the table is
    # handed to.

    use Elixir.Supervisor

    @server :server

    def start_link(opts), do: Elixir.Supervisor.start_link(__MODULE__, opts)

    @doc "The port the listener started as `supervisor` is bound to."
    def port(supervisor) when is_pid(supervisor) do
      {@server, bandit, _type, _modules} =
        supervisor |> Elixir.Supervisor.which_children() |> List.keyfind(@server, 0)

      {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
      port
    end

    @impl true
    def init(opts) do
      bind = Keyword.get(opts, :bind, {127, 0, 0, 1})
      port = Keyword.fetch!(opts, :port)
      nonces = Cyfr.Execution.HostListener.Nonces.new()

      children = [
        {Cyfr.Execution.HostListener.Nonces, nonces},
        Elixir.Supervisor.child_spec(
          {Bandit,
           plug: {Cyfr.Execution.HostListener, %{nonces: nonces}},
           scheme: :http,
           ip: bind,
           port: port,
           startup_log: false},
          id: @server
        )
      ]

      Elixir.Supervisor.init(children, strategy: :one_for_all)
    end
  end

  defmodule Nonces do
    @moduledoc false
    # The nonces host calls have presented, per attempt, remembered for
    # twice the header window (a header within the window on either side
    # of the clock still verifies) and swept on the window.

    use GenServer

    @window_ms Cyfr.WorkerAuth.window_ms()

    @doc "A new, empty nonce table, owned by the calling process."
    def new, do: :ets.new(__MODULE__, [:public, :set, write_concurrency: true])

    @doc "Whether the header's nonce was not presented for its attempt within the window, remembering it if so."
    @spec fresh?(:ets.table(), Cyfr.WorkerAuth.host_call(), integer()) :: boolean()
    def fresh?(table, %{attempt: attempt, nonce: nonce}, now),
      do: :ets.insert_new(table, {{attempt, nonce}, now + 2 * @window_ms})

    def start_link(table), do: GenServer.start_link(__MODULE__, table)

    @impl true
    def init(table) do
      Process.send_after(self(), :sweep, @window_ms)
      {:ok, table}
    end

    @impl true
    def handle_info(:sweep, table) do
      now = System.system_time(:millisecond)
      :ets.select_delete(table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])
      Process.send_after(self(), :sweep, @window_ms)
      {:noreply, table}
    end
  end
end
