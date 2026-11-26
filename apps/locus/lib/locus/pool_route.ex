# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.PoolRoute do
  @moduledoc """
  The pool wire's one route (`Prima.LocusPool`, "The pool wire"), as each
  Locus service serves it: the runtime's worker listener, the builds
  service and the backends service mount it at
  `Prima.LocusPool.route/0`, each with its own service's name, its own key
  and its way to ask its role's keeper for the report.

  A request, in order:

  1. **The header, before any of the body**, verified under the service's
     pool key (`Prima.LocusPool.held_pool_key/2`, derived here from the
     key the listener holds), within the header window, no nonce kept since the
     call reads only: `{:unauthorized, reason}`, `reason` the first of
     `:unknown_version`, `:malformed`, `:outside_window` and `:bad_mac`. A
     service holding no key verifies nothing (`:bad_mac`).
  2. **The body**, read within `Prima.LocusPool.max_request_bytes/0`
     (`{:too_large, :declared}` for a declared length past it, unread;
     `{:too_large, :read}` for one that ran past it as it was read, which
     the listener drains as its other routes do; each on a connection that
     closes), must be the one the
     header hashed (`{:unauthorized, :bad_mac}`).
  3. **The request**, read strictly: `{:bad_body, :version}` for another
     version, `{:bad_body, :malformed}` for anything else.
  4. **The report** of the role's keeper after the rev the body names:
     `:unavailable` for a keeper that does not answer or refuses it.

  The answer is `Prima.LocusPool.answer/1`, plain, as every answer a Locus
  service gives CYFR. A refusal is the listener's, in its own convention:
  this module answers what refused and sends nothing of its own. The key,
  the pool key and what the request carries are never logged.
  """

  import Plug.Conn

  alias Prima.LocusPool

  @typedoc "Why a pool request was refused, for the listener to answer in its own words."
  @type refusal ::
          {:unauthorized, :unknown_version | :malformed | :outside_window | :bad_mac}
          | {:too_large, :declared | :read}
          | {:bad_body, :version | :malformed}
          | :unavailable

  @typedoc "How the listener asks its role's keeper for the report after a rev."
  @type report :: (non_neg_integer() -> {:ok, LocusPool.report()} | {:error, term()})

  @doc """
  Serve the pool request on `conn` for `service`, holding its own `key`
  (nil for none), asking `report` for the role's report, at `now` in Unix
  milliseconds: the answered `conn`, or the refusal for the listener to
  send on the `conn` it returns.
  """
  @spec serve(Plug.Conn.t(), LocusPool.service(), binary() | nil, report(), integer()) ::
          {:ok, Plug.Conn.t()} | {:refused, Plug.Conn.t(), refusal()}
  def serve(conn, service, key, report, now) when is_function(report, 1) and is_integer(now) do
    with {:ok, pool_key} <- pool_key(conn, service, key),
         {:ok, body_hash} <- verified(conn, service, pool_key, now),
         {:ok, body, conn} <- body(conn),
         :ok <- hashed(conn, body_hash, body),
         {:ok, after_rev} <- request(conn, body),
         {:ok, report} <- reported(conn, report, after_rev) do
      {:ok,
       conn
       |> put_resp_content_type("application/json")
       |> send_resp(200, LocusPool.answer(report))}
    end
  end

  defp pool_key(_conn, service, key) when byte_size(key) == 32,
    do: {:ok, LocusPool.held_pool_key(service, key)}

  defp pool_key(conn, _service, _key), do: {:refused, closing(conn), {:unauthorized, :bad_mac}}

  defp verified(conn, service, pool_key, now) do
    with {:ok, header} <- Locus.Listener.auth_header(conn),
         {:ok, body_hash} <- LocusPool.verify_header(service, pool_key, header, now) do
      {:ok, body_hash}
    else
      :error -> {:refused, closing(conn), {:unauthorized, :malformed}}
      {:error, reason} -> {:refused, closing(conn), {:unauthorized, reason}}
    end
  end

  defp body(conn) do
    case Locus.Listener.read_bounded(conn, LocusPool.max_request_bytes(), true) do
      {:ok, body, conn} ->
        {:ok, body, conn}

      {:too_large, conn, {:declared, _bytes}} ->
        {:refused, closing(conn), {:too_large, :declared}}

      {:too_large, conn, :read} ->
        {:refused, closing(conn), {:too_large, :read}}

      {:unread, conn} ->
        {:refused, closing(conn), {:bad_body, :malformed}}
    end
  end

  defp hashed(conn, body_hash, body) do
    case LocusPool.verify_body(body_hash, body) do
      :ok -> :ok
      {:error, :bad_mac} -> {:refused, conn, {:unauthorized, :bad_mac}}
    end
  end

  defp request(conn, body) do
    case LocusPool.read_request_body(body) do
      {:ok, after_rev} -> {:ok, after_rev}
      {:error, reason} -> {:refused, conn, {:bad_body, reason}}
    end
  end

  defp reported(conn, report, after_rev) do
    case report.(after_rev) do
      {:ok, report} -> {:ok, report}
      {:error, _reason} -> {:refused, conn, :unavailable}
    end
  catch
    :exit, _reason -> {:refused, conn, :unavailable}
  end

  # A refusal before the body was read ends the connection: the body the
  # caller sent is still on it, unread.
  defp closing(conn), do: put_resp_header(conn, "connection", "close")
end
