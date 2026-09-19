# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuilderService do
  @max_health_bytes 4096
  @watch_ms 1_000
  @cancel_ms 15_000

  @moduledoc """
  The builds service: the listener side of `Cyfr.BuilderProtocol`, and the
  only thing that reaches `Locus.Builder`. It speaks that protocol and
  nothing else: two `POST` routes, versioned bodies, and answers that are
  lines, each at the status the protocol gives its class. Whatever is not
  one of its operations is refused as `malformed`.

  ## Health

  `POST /locus/v1/builds/health` answers without authentication, as the
  protocol says: the release and the toolchains, from a body read within
  #{@max_health_bytes} bytes.

  ## A build, in order

  1. **The header, before any of the body.** The `x-cyfr-auth` header is
     verified under this service's request key
     (`Cyfr.BuilderProtocol.verify_request_header/3`) and refused as
     `unauthorized`, in the protocol's order: `malformed`,
     `outside_window`, `bad_mac`. A service holding no key verifies
     nothing.
  2. **Replay.** A verified header's nonce is kept for as long as the
     header could verify again, and one seen in that time is refused
     `replayed`. Only a verified header's nonce is kept, so nobody without
     the key grows the table.
  3. **The bound.** A declared length past
     `Cyfr.BuilderProtocol.max_request_bytes/0` is refused `malformed`
     without reading; the body is then read up to that bound, and one that
     runs past it is refused the same way.
  4. **The body's hash.** The bytes read must be the ones the header named
     (`verify_body/2`), or the request is `unauthorized` (`bad_mac`).
  5. **The request.** Read strictly (`read_request/1`): another version is
     `protocol_mismatch`, anything else that does not read is `malformed`.
  6. **The deadline.** The build's budget is the time to the request's
     deadline or `Locus.Config.timeout_ms/0`, whichever is less; a
     deadline already passed is refused `timeout` with nothing run.
  7. **The build itself** is checked and packed (`Locus.Builder.prepare/1`):
     `malformed` for sources that make no build, `unavailable` for a
     missing toolchain or spawner.
  8. **The slot.** One of `Locus.BuildSlots` is taken for the request's
     `athanor_id`, never waited for: `capacity` names the total cap or the
     athanor's, whichever refused.

  Every refusal so far is the one line of the answer, at its class's
  status, and nothing was spawned for it. With the slot held the answer
  opens as a `200` stream of lines: each progress line as the build makes
  it, then one terminal line, the result or the refusal the build ended
  with (`timeout`, `memory`, `failed`, `unavailable`, `capacity`), carrying
  the lines streamed as its diagnostics (`Locus.Diagnostics`).

  ## How a build ends, and what is given back

  The build runs in a process of its own, linked to the connection's, which
  holds the slot. The slot goes back only once that process has ended, and
  it ends only once its executor has retired everything the build started:

  - **Its own end, its deadline, its memory bound**: the executor answers
    after the build's processes are gone, the terminal line is written and
    the slot released.
  - **The client gone**: the connection is asked every #{@watch_ms} ms
    whether its peer closed (Bandit leaves a request's socket passive, so a
    close is seen only by asking), and a line that cannot be written says
    the same. The build is cancelled (`Locus.Executor.cancel/1`), which
    ends its processes with no grace; the service waits up to
    #{@cancel_ms} ms for that, kills the build process if it has not
    ended, and releases the slot. Nothing more is written.
  - **The connection's process killed** (the listener stopping, a crash):
    the link ends the build process, whose executor's own watch ends the
    build (the spawner releases a dead caller's spawn, the direct launcher's
    janitor kills the group), and the slots' monitor gives the slot back.
  - **cyfr-spawn lost**: the spawner answers every run in flight and stops;
    each build's terminal line is `unavailable`, its slot is released, and
    the listener, which depends on the spawner, stops with it
    (`Locus.Application`).

  Nothing a request carries is logged: a refusal is logged by its class.
  """

  use Plug.Router, copy_opts_to_assign: :service_opts

  require Logger

  alias Cyfr.BuilderProtocol
  alias Locus.Diagnostics

  @nonces __MODULE__.Nonces
  @slots Locus.BuildSlots
  @content_type "application/x-ndjson"

  plug(:match)
  plug(:dispatch)

  @doc "Create the table of nonces seen, owned by the calling process."
  @spec init_nonces() :: :ok
  def init_nonces do
    if :ets.whereis(@nonces) == :undefined,
      do: :ets.new(@nonces, [:set, :public, :named_table, write_concurrency: true])

    :ok
  end

  match _ do
    case {conn.method, BuilderProtocol.operation(conn.request_path)} do
      {"POST", {:ok, :build}} ->
        build(conn, now(conn))

      {"POST", {:ok, :health}} ->
        health(conn)

      _ ->
        refuse(
          conn,
          {:malformed, "#{conn.method} on this path is no operation of the builds service"}
        )
    end
  end

  # The clock a header's window and a request's deadline are read against:
  # the system's, or the `:now` this plug was given (a test presenting the
  # shared vectors' headers at the vectors' instant).
  defp now(%Plug.Conn{assigns: %{service_opts: opts}}) do
    case Keyword.fetch(opts, :now) do
      {:ok, now} when is_function(now, 0) -> now.()
      :error -> System.system_time(:millisecond)
    end
  end

  # ————— health —————

  defp health(conn) do
    with {:ok, body, conn} <- read(conn, @max_health_bytes),
         :ok <- readable(BuilderProtocol.read_health_request(body), conn) do
      {:ok, line} =
        BuilderProtocol.encode_health(%{
          release: BuilderProtocol.release(),
          toolchains: Locus.Builder.available_toolchains()
        })

      answer(conn, 200, line)
    else
      {:refused, conn, refusal} -> refuse(conn, refusal)
    end
  end

  # ————— a build, up to its slot —————

  defp build(conn, now) do
    with {:ok, key} <- request_key(conn),
         {:ok, header} <- header(conn),
         {:ok, auth, body_hash} <- verify_header(conn, key, header, now),
         :ok <- fresh(conn, auth, now),
         {:ok, body, conn} <- read(conn, BuilderProtocol.max_request_bytes()),
         :ok <- verify_body(conn, body_hash, body),
         {:ok, request} <- readable(BuilderProtocol.read_request(body), conn),
         {:ok, budget_ms} <- budget(conn, request, now),
         {:ok, plan} <- prepared(conn, request),
         {:ok, slot} <- slot(conn, request) do
      try do
        stream(conn, plan, budget_ms)
      after
        Cyfr.Slots.release(@slots, slot)
      end
    else
      {:refused, conn, refusal} -> refuse(conn, refusal)
    end
  end

  defp request_key(conn) do
    case Locus.Config.request_key() do
      key when is_binary(key) -> {:ok, key}
      nil -> {:refused, conn, {:unauthorized, :bad_mac}}
    end
  end

  defp header(conn) do
    case get_req_header(conn, BuilderProtocol.auth_header()) do
      [header] -> {:ok, header}
      _ -> {:refused, conn, {:unauthorized, :malformed}}
    end
  end

  defp verify_header(conn, key, header, now) do
    case BuilderProtocol.verify_request_header(key, header, now) do
      {:ok, auth, body_hash} -> {:ok, auth, body_hash}
      {:error, reason} -> {:refused, conn, {:unauthorized, reason}}
    end
  end

  # A header verifies while its `ts` is within the window of this clock, so
  # from the moment it is seen it can verify for two windows at most; its
  # nonce is refused for that long.
  defp fresh(conn, %{nonce: nonce}, now) do
    :ets.select_delete(@nonces, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])

    if :ets.insert_new(@nonces, {nonce, now + 2 * BuilderProtocol.window_ms()}),
      do: :ok,
      else: {:refused, conn, {:unauthorized, :replayed}}
  end

  # The declared length first, so a body past the bound is refused without
  # a byte of it read; then the read itself, bounded for a body that
  # declares none.
  defp read(conn, max) do
    with :ok <- declared(conn, max) do
      case read_body(conn, length: max, read_length: max) do
        {:ok, body, conn} -> {:ok, body, conn}
        {:more, _head, conn} -> {:refused, closing(conn), runs_past(max)}
        {:error, _reason} -> {:refused, conn, {:malformed, "the body could not be read"}}
      end
    end
  end

  defp declared(conn, max) do
    with [text] <- get_req_header(conn, "content-length"),
         {bytes, ""} when bytes > max <- Integer.parse(text) do
      {:refused, closing(conn),
       {:malformed, BuilderProtocol.describe({:too_large, :request, bytes, max})}}
    else
      _ -> :ok
    end
  end

  defp runs_past(max),
    do: {:malformed, "the request runs past #{max} bytes; at most #{max} are read"}

  # What is left of a body past the bound is never drained: the answer
  # closes the connection. Every other refusal leaves the connection open,
  # so Bandit reads off the little that was sent and the client reads its
  # answer instead of a reset.
  defp closing(conn), do: put_resp_header(conn, "connection", "close")

  defp verify_body(conn, body_hash, body) do
    case BuilderProtocol.verify_body(body_hash, body) do
      :ok -> :ok
      {:error, reason} -> {:refused, conn, {:unauthorized, reason}}
    end
  end

  defp readable({:error, error}, conn), do: {:refused, conn, BuilderProtocol.refusal_for(error)}
  defp readable(read, _conn), do: read

  defp budget(conn, %{deadline: deadline}, now) do
    case min(deadline - now, Locus.Config.timeout_ms()) do
      budget_ms when budget_ms > 0 -> {:ok, budget_ms}
      _passed -> {:refused, conn, {:timeout, 0}}
    end
  end

  defp prepared(conn, request) do
    case Locus.Builder.prepare(request) do
      {:ok, plan} -> {:ok, plan}
      {:error, refusal} -> {:refused, conn, refusal}
    end
  end

  # A build never waits for a slot, so a slot server that does not answer
  # refuses within the call's grace instead of holding the request open.
  defp slot(conn, %{athanor_id: athanor_id}) do
    case Cyfr.Slots.acquire(@slots, athanor_id, :root, wait_ms: 0) do
      {:ok, slot} -> {:ok, slot}
      {:error, refusal} -> {:refused, conn, slot_refusal(refusal, Cyfr.Slots.status(@slots))}
    end
  end

  # The cap named is the running instance's, the one that refused.
  defp slot_refusal(:capacity, %{max: max}) when max > 0, do: {:capacity, max}
  defp slot_refusal(:key_cap, %{key_max: key_max}) when key_max > 0, do: {:capacity, key_max}

  defp slot_refusal(_refusal, _status),
    do: {:unavailable, "the builder's build slots are not answering"}

  # ————— the stream —————

  defp stream(conn, plan, budget_ms) do
    conn =
      conn
      |> put_resp_content_type(@content_type)
      # One request a connection: the peer's close is then the client's
      # leaving and nothing else, and what `peer_closed?/1` reads is nothing
      # this service owed an answer.
      |> put_resp_header("connection", "close")
      |> send_chunked(200)

    service = self()
    ref = make_ref()
    budget = Diagnostics.budget()

    on_progress = fn stage, message ->
      for {stage, message} <- Diagnostics.admit(budget, stage, message),
          do: send(service, {ref, :progress, stage, message})

      :ok
    end

    build =
      spawn_link(fn ->
        send(
          service,
          {ref, :done, Locus.Builder.run(plan, timeout_ms: budget_ms, on_progress: on_progress)}
        )
      end)

    follow(conn, %{ref: ref, build: build, monitor: Process.monitor(build), lines: []})
  end

  defp follow(conn, %{ref: ref, monitor: monitor} = s) do
    receive do
      {^ref, :progress, stage, message} ->
        {:ok, line} = BuilderProtocol.encode_progress(stage, message)

        case chunk(conn, [line, ?\n]) do
          {:ok, conn} -> follow(conn, %{s | lines: [Diagnostics.line(stage, message) | s.lines]})
          {:error, _closed} -> abandon(conn, s)
        end

      {^ref, :done, result} ->
        settle(s)
        finish(conn, s, result)

      # The build process ended without its answer: a fault of this
      # builder's, not a refusal of the wire's. The stream ends without a
      # terminal line, which the client reads as an answer it never got.
      {:DOWN, ^monitor, :process, _build, reason} ->
        Logger.error(
          "[Locus.BuilderService] a build's process ended without an answer: #{inspect(reason)}"
        )

        settle(s)
        conn
    after
      @watch_ms ->
        if peer_closed?(conn), do: abandon(conn, s), else: follow(conn, s)
    end
  end

  defp finish(conn, _s, {:error, :cancelled}), do: conn

  defp finish(conn, s, {:ok, built}) do
    diagnostics = Enum.reverse(s.lines)

    case BuilderProtocol.encode_result(Map.put(built, :diagnostics, diagnostics)) do
      {:ok, line} ->
        terminal(conn, line)

      # What the builder answered is not a result the wire carries; the
      # reader's own sentence says why.
      {:error, error} ->
        note =
          Diagnostics.line(:validating, Diagnostics.sentence(BuilderProtocol.describe(error)))

        refusal_line(conn, {:failed, {:status, 0}}, diagnostics ++ [note])
    end
  end

  defp finish(conn, s, {:error, refusal}), do: refusal_line(conn, refusal, Enum.reverse(s.lines))

  defp refusal_line(conn, refusal, diagnostics) do
    Logger.warning("[Locus.BuilderService] a build ended refused: #{elem(refusal, 0)}")
    {:ok, line} = BuilderProtocol.encode_refusal(bounded(refusal), diagnostics)
    terminal(conn, line)
  end

  defp terminal(conn, line) do
    case chunk(conn, [line, ?\n]) do
      {:ok, conn} -> conn
      {:error, _closed} -> conn
    end
  end

  # The client is gone: end the build, and return only once it has ended,
  # so the slot this process holds goes back after the build's processes.
  defp abandon(conn, %{build: build, monitor: monitor} = s) do
    Logger.warning("[Locus.BuilderService] the client left; its build is cancelled")
    Locus.Executor.cancel(build)

    receive do
      {:DOWN, ^monitor, :process, _build, _reason} -> :ok
    after
      @cancel_ms ->
        Process.unlink(build)
        Process.exit(build, :kill)

        receive do
          {:DOWN, ^monitor, :process, _build, _reason} -> :ok
        end
    end

    settle(s)
    conn
  end

  # The build process is over: nothing of it stays in this process's
  # mailbox, which serves the connection's next request.
  defp settle(%{ref: ref, build: build, monitor: monitor}) do
    Process.demonitor(monitor, [:flush])
    Process.unlink(build)
    flush(ref, build)
  end

  defp flush(ref, build) do
    receive do
      {^ref, _kind, _stage, _message} -> flush(ref, build)
      {^ref, _kind, _result} -> flush(ref, build)
      {:EXIT, ^build, _reason} -> flush(ref, build)
    after
      0 -> :ok
    end
  end

  # Bandit keeps a request's socket passive, so a peer that closed is seen
  # only by asking it. The request's body was read whole and the answer
  # closes the connection, so nothing read here is a request.
  defp peer_closed?(%Plug.Conn{
         adapter: {Bandit.Adapter, %{transport: %{socket: %ThousandIsland.Socket{} = socket}}}
       }) do
    case ThousandIsland.Socket.recv(socket, 0, 0) do
      {:error, :timeout} -> false
      {:error, _closed} -> true
      {:ok, _bytes} -> false
    end
  end

  defp peer_closed?(_conn), do: false

  # ————— answers —————

  defp refuse(conn, refusal) do
    Logger.warning("[Locus.BuilderService] #{conn.method} refused: #{elem(refusal, 0)}")
    {:ok, line} = BuilderProtocol.encode_refusal(bounded(refusal), [])
    answer(conn, BuilderProtocol.status(refusal), line)
  end

  defp answer(conn, status, line) do
    conn
    |> put_resp_content_type(@content_type)
    |> send_resp(status, [line, ?\n])
  end

  # A sentence may quote what the request named, a path among it; the wire
  # bounds a sentence, so it is cut to fit rather than failing to encode.
  defp bounded({class, sentence}) when class in [:malformed, :unavailable],
    do: {class, Diagnostics.sentence(sentence)}

  defp bounded(refusal), do: refusal
end
