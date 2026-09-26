# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.WorkerListener do
  @moduledoc """
  Where CYFR's requests reach this worker service: one `POST` route per
  callback of `Prima.WorkerAPI`, as `Prima.WorkerWire` spells them, served
  by Bandit on the address `Opus.Credentials` names.

  A request is verified before its body is read, in the order
  `Prima.WorkerAuth` documents: the route (`404`); this service's
  credentials, without which it is addressed by nobody (`503`); exactly
  one `x-cyfr-auth` header; then the header itself under this service's
  dispatch key (`Prima.WorkerAuth.verify_request_header/3`) —
  `unknown_version` for a version token other than `v1`, `malformed`,
  `outside_window`, `bad_mac` — a header naming another service
  (`malformed`), and a nonce presented within the header window
  (`replayed`), each refused `401`. A refusal made before the body is read
  is answered on a closed connection, so the unread body is never taken
  for the next request. The body is then read up to
  `Prima.HostAPI.max_body_bytes/0`, checked against the hash the header
  named (`Prima.WorkerAuth.verify_body/2`), and read as the request of the
  route's callback (`Prima.WorkerWire.read_request_body/2`): its version
  first, a missing `v` or another being `unknown_version`, then its
  callback, a body naming another than its route's being `malformed`, each
  refused `400`. `start` carries `assignment`, `input` and `sealed_keys`,
  `kill` an `execution_id`, `status` nothing. The callback runs on
  `Opus.WorkerService`, and its answer is the plain, unsigned
  `Prima.WorkerWire` answer at this wire's version: `{"v": 1, "ok": true}`
  for a start or a kill, `{"v": 1, "ok": status}` for the status as
  `Prima.WorkerAPI.status_to_wire/1` writes it, `{"v": 1, "error": name}`
  for a start that is `malformed` or a kill that finds nothing. A start no
  runner can take is refused `503` `unavailable`, with a `message` naming
  why while the keeper refuses runners.

  Nothing a request carries is logged: a refusal is logged by its reason.
  """

  use Plug.Router

  require Logger

  alias Prima.{HostAPI, WorkerAPI, WorkerAuth, WorkerWire}

  @nonces __MODULE__.Nonces

  plug(:match)
  plug(:dispatch)

  @doc "Create the table of nonces seen, owned by the calling process."
  @spec init_nonces() :: :ok
  def init_nonces do
    if :ets.whereis(@nonces) == :undefined,
      do: :ets.new(@nonces, [:set, :public, :named_table, write_concurrency: true])

    :ok
  end

  post "/worker/v1/*_rest" do
    serve(conn, System.system_time(:millisecond))
  end

  match _ do
    refuse(closing(conn), 404, :not_found)
  end

  defp serve(conn, now) do
    with {:ok, callback} <- route(conn),
         {:ok, credentials} <- credentials(),
         {:ok, header} <- header(conn),
         {:ok, request, body_hash} <- verify_header(credentials, header, now),
         :ok <- addressed(request, credentials),
         :ok <- fresh(request, now),
         {:ok, body, read} <- read(conn),
         {:ok, args} <- read_request(read, body_hash, body, callback) do
      answer(read, callback, args)
    else
      # A refusal after the body was read answers on the conn that read it.
      {:refused, read, status, reason} -> refuse(read, status, reason)
      {:refused, status, reason} -> refuse(closing(conn), status, reason)
    end
  end

  # A refusal made before the body was read ends the connection: the body
  # the caller sent is still on it, unread.
  defp closing(conn), do: put_resp_header(conn, "connection", "close")

  defp route(conn) do
    case WorkerWire.worker_callback(conn.request_path) do
      {:ok, callback} -> {:ok, callback}
      :error -> {:refused, 404, :not_found}
    end
  end

  defp credentials do
    case Opus.Credentials.current() do
      %Opus.Credentials{} = credentials -> {:ok, credentials}
      nil -> {:refused, 503, :unavailable}
    end
  end

  defp header(conn) do
    case get_req_header(conn, WorkerWire.auth_header()) do
      [header] -> {:ok, header}
      _ -> {:refused, 401, :malformed}
    end
  end

  defp verify_header(credentials, header, now) do
    case WorkerAuth.verify_request_header(credentials.dispatch_key, header, now) do
      {:ok, request, body_hash} -> {:ok, request, body_hash}
      {:error, reason} -> {:refused, 401, reason}
    end
  end

  # The MAC verified under this service's key, so the header is CYFR's;
  # one naming another service was not made for this one.
  defp addressed(%{service: service}, %{service_id: service}), do: :ok
  defp addressed(_request, _credentials), do: {:refused, 401, :malformed}

  # A nonce is refused for the header window on either side of its
  # timestamp, which is as long as the header itself verifies.
  defp fresh(%{nonce: nonce}, now) do
    :ets.select_delete(@nonces, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])

    if :ets.insert_new(@nonces, {nonce, now + 2 * WorkerAuth.window_ms()}),
      do: :ok,
      else: {:refused, 401, :replayed}
  end

  defp read(conn) do
    max = HostAPI.max_body_bytes()

    case read_body(conn, length: max, read_length: max) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _chunk, conn} -> {:refused, closing(conn), 413, :malformed}
      {:error, _reason} -> {:refused, 400, :malformed}
    end
  end

  defp read_request(read, body_hash, body, callback) do
    with :ok <- verify_body(body_hash, body),
         {:ok, args} <- decode(body, callback) do
      {:ok, args}
    else
      {:refused, status, reason} -> {:refused, read, status, reason}
    end
  end

  defp verify_body(body_hash, body) do
    case WorkerAuth.verify_body(body_hash, body) do
      :ok -> :ok
      {:error, reason} -> {:refused, 401, reason}
    end
  end

  # The body's version is read before its callback.
  defp decode(body, callback) do
    with {:ok, decoded} <- Jason.decode(body),
         {:ok, ^callback, args} <- WorkerWire.read_request_body(WorkerAPI, decoded) do
      {:ok, args}
    else
      {:error, :unknown_version} -> {:refused, 400, :unknown_version}
      _ -> {:refused, 400, :malformed}
    end
  end

  defp answer(conn, callback, args) do
    case run(callback, args) do
      {:ok, value} ->
        send_answer(conn, 200, WorkerWire.ok(value))

      {:error, :malformed} when callback == :start ->
        send_answer(conn, 200, WorkerWire.error(:malformed))

      {:error, :not_found} when callback == :kill ->
        send_answer(conn, 200, WorkerWire.error(:not_found))

      {:error, :malformed} ->
        refuse(conn, 400, :malformed)

      {:error, :unavailable} ->
        refuse(conn, 503, :unavailable)

      {:error, {:unavailable, message}} ->
        Logger.warning(
          "[Opus.WorkerListener] #{conn.method} #{conn.request_path} refused: unavailable " <>
            "(#{message})"
        )

        send_answer(conn, 503, WorkerWire.error(:unavailable, %{"message" => message}))
    end
  end

  defp run(:start, %{"assignment" => token, "input" => input, "sealed_keys" => sealed})
       when is_binary(token) and is_binary(input) and is_binary(sealed) do
    case Opus.WorkerService.start(token, input, sealed) do
      :ok -> {:ok, true}
      {:error, :malformed} -> {:error, :malformed}
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, {:unavailable, message}} -> {:error, {:unavailable, message}}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp run(:kill, %{"execution_id" => id}) when is_binary(id) and id != "" do
    case Opus.WorkerService.kill(id) do
      :ok -> {:ok, true}
      {:error, :not_found} -> {:error, :not_found}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp run(:status, args) when map_size(args) == 0 do
    {:ok, status} = Opus.WorkerService.status()
    {:ok, WorkerAPI.status_to_wire(status)}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp run(_callback, _args), do: {:error, :malformed}

  defp refuse(conn, status, reason) do
    Logger.warning("[Opus.WorkerListener] #{conn.method} #{conn.request_path} refused: #{reason}")
    send_answer(conn, status, WorkerWire.error(reason))
  end

  defp send_answer(conn, status, answer) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(answer))
  end
end
