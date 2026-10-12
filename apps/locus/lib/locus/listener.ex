# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Listener do
  @moduledoc """
  The checks the island's signed listeners share, each written once:
  `Locus.Runtime.WorkerListener`, `Locus.BuilderService` and
  `Locus.Backends.Service` call them from their own sequences, in their
  own order, and turn each answer into their own refusal. Nothing here
  answers a request, chooses a status or decides whether a connection
  closes, and nothing here logs: what a listener refuses, and how, is the
  listener's.

  - `auth_header/1`: the one `x-cyfr-auth` header a request carries.
  - `init_nonces/1` and `fresh/4`: a table of the nonces seen within a
    header window, for a listener that stores a verified header's nonce
    before it reads the body (the runtime's and the builds').
  - `read_bounded/3`: the body, read to a bound and no further.
  - `drain/2`: what the client still sends of a body refused past its
    bound, read and dropped after the refusal under one deadline.
  - `now/1`: the clock a request's header is read against.
  """

  import Plug.Conn, only: [get_req_header: 2, read_body: 2]

  @doc """
  The request's `x-cyfr-auth` header (`Prima.MacEnvelope.auth_header/0`),
  or `:error` for none or more than one.
  """
  @spec auth_header(Plug.Conn.t()) :: {:ok, String.t()} | :error
  def auth_header(conn) do
    case get_req_header(conn, Prima.MacEnvelope.auth_header()) do
      [header] -> {:ok, header}
      _ -> :error
    end
  end

  @doc """
  Create `table`, the nonces one listener has seen, owned by the calling
  process; a table that exists already is kept, with what it holds.
  """
  @spec init_nonces(atom()) :: :ok
  def init_nonces(table) do
    if :ets.whereis(table) == :undefined,
      do: :ets.new(table, [:set, :public, :named_table, write_concurrency: true])

    :ok
  end

  @doc """
  Whether `nonce` is seen for the first time at `now`, in Unix
  milliseconds, recording it when it is. A header verifies while its
  timestamp is within `window_ms` of the clock, so from the moment it is
  seen it can verify for two windows at most: a nonce is refused for that
  long, and a row past it is swept here.
  """
  @spec fresh(atom(), String.t(), integer(), pos_integer()) :: :ok | {:error, :replayed}
  def fresh(table, nonce, now, window_ms) do
    :ets.select_delete(table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])

    if :ets.insert_new(table, {nonce, now + 2 * window_ms}),
      do: :ok,
      else: {:error, :replayed}
  end

  @doc """
  The request's body, read to `max` bytes. With `declared?`, a
  `content-length` past `max` is refused before a byte is read
  (`{:too_large, conn, {:declared, bytes}}`); a body that runs past `max`
  as it is read is `{:too_large, conn, :read}`, and one that cannot be
  read `{:unread, conn}`. No answer sets a header: whether the refusal
  closes the connection is the caller's.
  """
  @spec read_bounded(Plug.Conn.t(), pos_integer(), boolean()) ::
          {:ok, binary(), Plug.Conn.t()}
          | {:too_large, Plug.Conn.t(), {:declared, non_neg_integer()} | :read}
          | {:unread, Plug.Conn.t()}
  def read_bounded(conn, max, declared?) do
    with :ok <- declared(conn, max, declared?) do
      case read_body(conn, length: max, read_length: max) do
        {:ok, body, conn} -> {:ok, body, conn}
        {:more, _head, conn} -> {:too_large, conn, :read}
        {:error, _reason} -> {:unread, conn}
      end
    end
  end

  defp declared(_conn, _max, false), do: :ok

  defp declared(conn, max, true) do
    with [text] <- get_req_header(conn, "content-length"),
         {bytes, ""} when bytes > max <- Integer.parse(text) do
      {:too_large, conn, {:declared, bytes}}
    else
      _ -> :ok
    end
  end

  @doc """
  What the client still sends of a body refused past its bound, read and
  dropped once the refusal was sent on `conn`, which closes. A client that
  writes its whole body before it reads its answer so reads the refusal,
  where a connection closed on unread bytes resets under it and loses the
  answer.

  At most `max` bytes more are read in all, each read dropped before the
  next, under one deadline for the whole of them: the listener's receive
  timeout (ThousandIsland's `read_timeout`, which the listener's Bandit
  options configure), counted from the drain's start. Each read waits only
  for what is left of it, and at the deadline the connection's reading
  side is shut, which also ends a read Bandit makes of several receives,
  as it reads a chunked body. The shut is made by a process the drain
  starts, which stops with the drain or with the connection's process.
  The body's end, the bound, the deadline or the client's leaving ends
  the drain. A connection that is not Bandit's HTTP/1 socket, or whose
  receive timeout is unbounded, is answered as it is, with the rest
  unread.
  """
  @spec drain(Plug.Conn.t(), pos_integer()) :: Plug.Conn.t()
  def drain(conn, max) do
    case receive_timeout(conn) do
      {:ok, socket, timeout} ->
        deadline = System.monotonic_time(:millisecond) + timeout
        shut = spawn(__MODULE__, :shut_at, [self(), socket, deadline])

        try do
          drop(conn, max, deadline)
        after
          send(shut, :stop)
        end

      :error ->
        conn
    end
  end

  @doc false
  # The deadline's shut, a process of its own beside the connection's,
  # which is blocked in a receive when the deadline comes: it shuts the
  # socket's reading side at `deadline`, a monotonic millisecond the drain
  # computed before starting it, so a late start waits only for what is
  # left of the one deadline; unless it is told to stop first or the
  # connection's process `owner` ends, so no shut outlives the drain it
  # bounds.
  @spec shut_at(pid(), ThousandIsland.Socket.t(), integer()) :: :ok
  def shut_at(owner, socket, deadline) do
    watch = Process.monitor(owner)
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      :stop -> :ok
      {:DOWN, ^watch, :process, ^owner, _reason} -> :ok
    after
      left ->
        _ = ThousandIsland.Socket.shutdown(socket, :read)
        :ok
    end
  end

  defp receive_timeout(%Plug.Conn{
         adapter:
           {Bandit.Adapter,
            %{transport: %{socket: %ThousandIsland.Socket{read_timeout: timeout} = socket}}}
       })
       when is_integer(timeout),
       do: {:ok, socket, timeout}

  defp receive_timeout(_conn), do: :error

  # Each read's length is also its receive size, so a body of declared
  # length takes one receive a read, which waits no longer than the time
  # left; the several receives of a chunked body's read are ended by the
  # shut at the deadline.
  defp drop(conn, rest, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if rest > 0 and left > 0 do
      case read_dropped(conn, length: rest, read_length: rest, read_timeout: left) do
        {:more, dropped, conn} -> drop(conn, rest - byte_size(dropped), deadline)
        {:ok, _dropped, conn} -> conn
        {:error, _reason} -> conn
      end
    else
      conn
    end
  end

  # Bandit raises when a read times out, the client has gone or the
  # reading side was shut; either way nothing more of the body arrives.
  defp read_dropped(conn, opts) do
    read_body(conn, opts)
  rescue
    _gone in [Bandit.HTTPError, Bandit.TransportError] -> {:error, :gone}
  end

  @doc """
  The clock a request's header window, deadline and nonce expiry are read
  against, in Unix milliseconds, for a plug that copies its options to
  `:service_opts`: the `:now` function among them (a test presenting the
  shared vectors' headers at the vectors' instant), or the system's.
  """
  @spec now(Plug.Conn.t()) :: integer()
  def now(%Plug.Conn{assigns: %{service_opts: opts}}) do
    case Keyword.fetch(opts, :now) do
      {:ok, now} when is_function(now, 0) -> now.()
      :error -> System.system_time(:millisecond)
    end
  end
end
