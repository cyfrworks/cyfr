# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.HostListener do
  @moduledoc """
  The HTTP face of `Crucible.Host`: one Bandit listener of its own,
  serving the host routes `Prima.WorkerWire` declares, on the bind address
  and port its child spec is given. A worker service posts its runners'
  host calls here, each as the runner signed it under its attempt's keys
  and the service verified it before posting it unchanged, and its runner
  exit reports; nothing else is served.

  Every request is refused as early as its evidence allows, before any
  authorized action and, for anything the header alone decides, before
  the body is read, in the order `Prima.WorkerAuth` documents and
  `tests/fixtures/host_api.json`'s `pre_body_refusals` pin:

    1. the route is a host route and the method is `POST`, else `404`;
    2. this boot holds the control plane (`Arca.ControlPlane.held?/0`),
       else `503`, answered as `Crucible.Host` would refuse it;
    3. the `x-cyfr-auth` header is present exactly once, else `401`;
    4. the header verifies over its fields and the body hash it names — a
       host call under the call key of the attempt it names, at this
       member's standing (`Crucible.Keys.standing/0`: its generation and
       its own boot, so a call addressed to a peer is refused here,
       `Prima.WorkerAuth.verify_host_call_header/4`), a report under the
       dispatch key of the worker service it names
       (`Prima.WorkerAuth.verify_report_header/3`) — refused `401`, in
       the verifier's order: a version token other than `v1`, then a
       header that does not parse, a timestamp outside the window, a MAC
       that is not the key's, another generation and another member;
    5. for a callback that is not idempotent (`Prima.HostAPI.retry/1`), the
       header's nonce has not been presented for its attempt within the
       window before, else `401`;
    6. for every call but `attach`, which is the claim, the attempt row is
       running at the header's fence and claimed by the runner the header
       names (`Arca.ExecutionAttempts.held?/4`): the runner id is the worker
       service's, the one it verified before it posted the call. A header
       naming any other runner, or an attempt no runner holds, is answered
       as `Host` answers it, `lost` (`unavailable` when the store cannot
       answer), sealed for the call as any answer is, on a connection the
       listener closes, and its body is never read.

  Each of those is answered on a connection the listener closes, and the
  body is never read. Then:

    6. the body is at most `Prima.HostAPI.max_body_bytes/0`, else `413`
       (on a closed connection, since the rest is left unread), and is
       the one the header named (`Prima.WorkerAuth.verify_body/2`), else
       `401`;
    7. a host call's body opens as the `:body` of the call the header
       names, under the attempt's seal key derived from the root
       (`Prima.WorkerAuth.open_call/4`), else `401`;
    8. the body is at this wire's version, else `400` `unknown_version`,
       read before its `op`, and its `op` is the route's callback with
       arguments that are an object, else `400` `malformed`
       (`Prima.WorkerWire.read_request_body/2`).

  A host call crosses sealed: its HTTP body is
  `Prima.WorkerAuth.seal_call/5` of the `{"v", "op", "args"}` JSON in the
  `:body` direction, the header is computed over those sealed bytes, and
  the answer is the JSON `Crucible.Host.call/2` produces sealed in
  the `:answer` direction under the same call. `Host.call/2` reads the
  JSON and verifies its header over it, so the listener hands it the
  opened JSON under the verified fields re-signed over that JSON with the
  attempt's call key, which CYFR derives from the root as `Host` does:
  the fields, timestamp and nonce are the runner's, and `Host` verifies
  the whole call again itself. A report (`runner_exited`) crosses as
  plain JSON under its report header, and its answer is plain.

  Every listener refusal is written by `Prima.WorkerWire.error/2`, so it
  carries the wire's version, and is `{"v": 1, "error": "lost"}` but the
  unknown route's `not_found`, an unowned report's `unavailable`, a
  header or body at another version's `unknown_version` (a peer at
  another version of the wire is told so) and a body that is not the
  route's call's `malformed`; the reason is logged, the header and body
  never. An answer, sealed or plain, is sent as `200` whatever it says: a
  refusal `Host` answers is an answer, not a transport failure. This
  listener's checks are defence in depth, and keep an unauthenticated
  caller from making CYFR read what it sent.

  Nothing here is configured from the application environment: the
  supervisor that starts it names the bind, the port and the drain
  (`child_spec/1`), so a test binds port 0 and reads what it was given
  (`port/1`).
  """

  use Plug.Router, copy_opts_to_assign: :host_listener

  require Logger

  alias Prima.{HostAPI, WorkerAuth, WorkerWire}
  alias Crucible.{Host, Keys}

  plug(:match)
  plug(:dispatch)

  @typedoc """
  How the listener is started: the address to bind, the port (0 for any
  free one) and the drain, in milliseconds.
  """
  @type option ::
          {:bind, :inet.ip_address()}
          | {:port, :inet.port_number()}
          | {:drain_ms, non_neg_integer()}

  @doc """
  The listener's child spec: a supervisor of the nonce memory, the node's
  pin table (`Crucible.Host.Egress`) and the Bandit server, bound to
  `:bind` (default loopback) on `:port` (required).
  On shutdown the server stops accepting and lets the connections already
  open finish for `:drain_ms` (default 5 000) before it closes them.
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
      _ -> refuse(close(conn), 404, :not_found)
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
         :ok <- claimed(callback, fields),
         {:ok, body, read} <- bounded_body(conn),
         :ok <- verify_body(read, body_hash, body),
         {:ok, call} <- open(read, callback, fields, header, body),
         :ok <- names_route(read, callback, call.json) do
      read
      |> put_resp_content_type("application/json")
      |> send_resp(200, answer(callback, fields, call))
    else
      # A refusal after the body was read answers on the conn that read it;
      # one before it, or with the body read only in part, closes the
      # connection, so nothing more of the body is read to reuse it.
      {:answered, fields, name} -> answer_unread(close(conn), fields, name)
      {:refused, read, status, name} -> refuse(read, status, name)
      {:refused, status, name} -> refuse(close(conn), status, name)
      {:refused_unread, read, status, name} -> refuse(close(read), status, name)
    end
  end

  # A boot that does not hold the control plane answers for no attempt;
  # `Host` refuses with the same word, so it is answered before the body
  # is read.
  defp owned(callback) do
    if Arca.ControlPlane.held?() do
      :ok
    else
      Logger.warning(
        "[Crucible.HostListener] #{callback} refused: this boot does not hold the " <>
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
          "[Crucible.HostListener] refused: #{length(headers)} " <>
            "#{WorkerWire.auth_header()} headers"
        )

        {:refused, 401, :lost}
    end
  end

  # A peer at another version of the wire is told so; every other header
  # refusal is `lost`, its reason logged.
  defp header_refused(callback, :unknown_version) do
    Logger.warning("[Crucible.HostListener] #{callback} refused: unknown_version")
    {:refused, 401, :unknown_version}
  end

  defp header_refused(callback, reason) do
    Logger.warning("[Crucible.HostListener] #{callback} refused: #{reason}")
    {:refused, 401, :lost}
  end

  # A report verifies under the dispatch key of the service it names; a
  # host call under the call key of the attempt it names, at this
  # member's standing. A generation the control plane cannot answer
  # verifies nothing, and a call naming another member is refused before
  # its body is read.
  defp verify_header(:runner_exited, header, now) do
    case WorkerAuth.verify_report_header(Keys.root(), header, now) do
      {:ok, fields, body_hash} -> {:ok, fields, body_hash}
      {:error, reason} -> header_refused(:runner_exited, reason)
    end
  end

  defp verify_header(callback, header, now) do
    with {:ok, standing} <- Keys.standing(),
         {:ok, fields, body_hash} <-
           WorkerAuth.verify_host_call_header(Keys.root(), header, now, standing) do
      {:ok, fields, body_hash}
    else
      {:error, :unavailable} ->
        Logger.warning(
          "[Crucible.HostListener] #{callback} refused: the control-plane generation " <>
            "is not known"
        )

        {:refused, 503, :lost}

      {:error, reason} ->
        header_refused(callback, reason)
    end
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
        "[Crucible.HostListener] #{callback} refused: replayed, the nonce was presented " <>
          "before"
      )

      {:refused, 401, :lost}
    end
  end

  # Every call after attach is the claiming runner's: the row must be
  # running at the header's fence and claimed by the runner the header
  # names, the one the worker service verified before posting. Attach is
  # the claim itself, and a report names no attempt of its own. `Host`
  # checks the hold again, under the attempt's grant.
  defp claimed(callback, _fields) when callback in [:attach, :runner_exited], do: :ok

  defp claimed(callback, fields) do
    case Arca.ExecutionAttempts.held?(
           Prima.Actor.in_athanor(fields.athanor_id),
           fields.attempt,
           fields.fence,
           fields.runner
         ) do
      true ->
        :ok

      false ->
        Logger.warning(
          "[Crucible.HostListener] #{callback} refused: the attempt is not claimed by the " <>
            "runner the header names"
        )

        {:answered, fields, :lost}

      {:error, _reason} ->
        Logger.warning(
          "[Crucible.HostListener] #{callback} refused: the attempt's claim could not be read"
        )

        {:answered, fields, :unavailable}
    end
  end

  # `Host`'s own answer for a call it would refuse on the same row, given
  # before the body is read: sealed for the header's call under the
  # attempt's seal key, so the runner reads it as the answer it is and
  # never as a lost one.
  defp answer_unread(conn, fields, name) do
    {:ok, seal_key} = WorkerAuth.attempt_seal_key(Keys.root(), fields)
    json = Jason.encode!(WorkerWire.error(name))
    {:ok, sealed} = WorkerAuth.seal_call(seal_key, :answer, fields, json)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, sealed)
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
        Logger.warning("[Crucible.HostListener] refused: the body exceeds #{max} bytes")
        {:refused_unread, conn, 413, :lost}

      {:error, _reason} ->
        Logger.warning("[Crucible.HostListener] refused: the body could not be read")
        {:refused, 400, :lost}

      {:refused, _status, _name} = refused ->
        refused
    end
  end

  defp declared_length(conn, max) do
    with [length] <- get_req_header(conn, "content-length"),
         {declared, ""} when declared > max <- Integer.parse(length) do
      Logger.warning(
        "[Crucible.HostListener] refused: the body declares #{declared} bytes, over #{max}"
      )

      {:refused, 413, :lost}
    else
      _ -> :ok
    end
  end

  defp verify_body(read, body_hash, body) do
    case WorkerAuth.verify_body(body_hash, body) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Crucible.HostListener] refused: the body is not the header's: #{reason}")

        {:refused, read, 401, :lost}
    end
  end

  # A report crosses plain. A host call's body opens under the attempt's
  # seal key as the `:body` of the header's call, and the opened JSON is
  # handed to `Host` under the same verified fields, signed over it with
  # the attempt's call key, since `Host` verifies the header over the body
  # it reads. Both keys derive from the root and the verified fields.
  defp open(_read, :runner_exited, _fields, header, body),
    do: {:ok, %{header: header, json: body}}

  defp open(read, callback, fields, _header, body) do
    {:ok, seal_key} = WorkerAuth.attempt_seal_key(Keys.root(), fields)

    case WorkerAuth.open_call(seal_key, :body, fields, body) do
      {:ok, json} ->
        {:ok, call_key} = WorkerAuth.attempt_call_key(Keys.root(), fields)
        {:ok, header} = WorkerAuth.host_call_header(call_key, fields, json)
        {:ok, %{header: header, json: json, seal_key: seal_key}}

      {:error, :unsealable} ->
        Logger.warning(
          "[Crucible.HostListener] #{callback} refused: the body does not open as the " <>
            "header's call"
        )

        {:refused, read, 401, :lost}
    end
  end

  defp answer(:runner_exited, _fields, call), do: Host.runner_exited(call.header, call.json)

  defp answer(_callback, fields, call) do
    {:ok, sealed} =
      WorkerAuth.seal_call(call.seal_key, :answer, fields, Host.call(call.header, call.json))

    sealed
  end

  # The opened body is read at this wire's version before its `op`, and the
  # route and the body name the same callback, so a body cannot be posted
  # at another route.
  defp names_route(read, callback, body) do
    read_body =
      case Jason.decode(body) do
        {:ok, decoded} -> WorkerWire.read_request_body(HostAPI, decoded)
        {:error, _not_json} -> {:error, :malformed}
      end

    case read_body do
      {:ok, ^callback, _args} ->
        :ok

      {:error, :unknown_version} ->
        Logger.warning(
          "[Crucible.HostListener] #{callback} refused: the body is at another version"
        )

        {:refused, read, 400, :unknown_version}

      _other ->
        Logger.warning("[Crucible.HostListener] #{callback} refused: the body does not name it")

        {:refused, read, 400, :malformed}
    end
  end

  defp close(conn), do: put_resp_header(conn, "connection", "close")

  defp refuse(conn, status, name) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(WorkerWire.error(name)))
  end

  defmodule Supervisor do
    @moduledoc false
    # One listener: the nonce table, owned here so a request that crashes
    # forgets nothing, its sweeper, the node's pin table (the first
    # listener's; a later one starts none) and the Bandit server the nonce
    # table is handed to.

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
      drain_ms = Keyword.get(opts, :drain_ms, 5_000)
      nonces = Crucible.HostListener.Nonces.new()

      children = [
        {Crucible.HostListener.Nonces, nonces},
        Crucible.Host.Egress.Pins,
        Elixir.Supervisor.child_spec(
          {Bandit,
           plug: {Crucible.HostListener, %{nonces: nonces}},
           scheme: :http,
           ip: bind,
           port: port,
           startup_log: false,
           thousand_island_options: [shutdown_timeout: drain_ms]},
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

    @window_ms Prima.WorkerAuth.window_ms()

    @doc "A new, empty nonce table, owned by the calling process."
    def new, do: :ets.new(__MODULE__, [:public, :set, write_concurrency: true])

    @doc "Whether the header's nonce was not presented for its attempt within the window, remembering it if so."
    @spec fresh?(:ets.table(), Prima.WorkerAuth.host_call(), integer()) :: boolean()
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
