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
