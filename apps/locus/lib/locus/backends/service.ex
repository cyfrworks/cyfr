# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.Service do
  @max_health_bytes 4096

  @moduledoc """
  The backends service: the listener side of `Prima.LocusBackends`, and
  the only thing that reaches `Locus.Backends.Owners` from outside. Three
  `POST` routes; whatever is not one of them is refused `bad_request`, and
  every refusal is `Prima.LocusBackends.encode_refusal/1` at its code's
  status. Every answer carries `x-cyfr-boot`, the service's lifetime
  (`Locus.Backends.Owners.boot/1`).

  ## Health

  `POST /locus/v1/backends/health` answers without authentication: a
  `{"version": 2}` body (`Prima.LocusBackends.read_health/1`), read within
  #{@max_health_bytes} bytes, is answered with the protocol version and the
  release; a body at another version is refused `version`.

  ## A control message, in order

  1. **The header, before any of the body**, verified under the control
     key (`Prima.LocusBackends.verify_header/4`): `unauthorized` (401).
  2. **The lifetime**: the header's `boot` must be this service's or `-`,
     else `stale_boot`.
  3. **The sequence**: its `(generation, seq)` must be above every control
     message applied, else `stale_control`.
  4. **The body**, read within `max_control_bytes/0` (`too_large`, 413),
     must be the one the header hashed (`unauthorized`).
  5. **The message**, read strictly (`read_control/1`): another version is
     `version` before its type is read; anything else that does not read is
     refused as `refusal_for/1` names it (`too_many_owners` for a status
     naming too many owners).
  6. **The lifetime again**: a `hello` names `-`, every other type this
     service's boot, else `stale_boot`.
  7. **The apply**: the owners apply it after every message before it, and
     check its sequence again there (`stale_control`); its answer is
     encoded as `encode_answer/2` encodes it, and a status answer past
     `max_status_answer_bytes/0` is refused whole as `status_too_large`.

  ## A session message, in order

  1. **The header**, verified as an invoke under the key of the owner it
     names: `unauthorized`.
  2. **The lifetime**: the header's `boot` must be this service's, else
     `stale_boot`.
  3. **The owner**, at exactly the header's generation and epoch
     (`Locus.Backends.Owners.admit/2`): `unknown_owner`, `stale_epoch`,
     `epoch_ahead`, `lapsed`.
  4. **The nonce**: one seen at this owner version within its window is
     `replay`; an owner version holding `max_nonces/0` live nonces is
     `nonce_cache_full` (503).
  5. **The body**, read within `max_session_bytes/0` (`too_large`, 413),
     must be the one the header hashed (`unauthorized`).
  6. **The owner and the nonce again**, and the nonce recorded: only a
     request whose body was the one signed records one.
  7. **The message**, read strictly (`read_session/1`), naming the owner
     and epoch its header names (`bad_request`).
  8. **The session**: `open` through the owners (`Locus.Backends.Owners.open/3`);
     `send`, `recv` and `close` to the session the owners name
     (`unknown_session` for one they do not hold), so a `recv` that waits
     holds its session and nothing else.

  Every refusal made before the body is read closes the connection, so
  the body is never read. What a session answers is masked with its
  owner's secret values before it leaves. Nothing a request carries is
  logged: a refusal is logged by its code.
  """

  use Plug.Router, copy_opts_to_assign: :service_opts

  require Logger

  alias Locus.Backends.{Backend, Owners}
  alias Locus.Listener
  alias Prima.LocusBackends

  @nonces __MODULE__.Nonces
  @json "application/json"

  plug(:match)
  plug(:dispatch)

  @doc """
  Create the table of nonces seen, owned by the calling process: one row
  per owner version and nonce, ordered so one owner version's rows are
  counted without reading another's.
  """
  @spec init_nonces() :: :ok
  def init_nonces do
    if :ets.whereis(@nonces) == :undefined,
      do: :ets.new(@nonces, [:ordered_set, :public, :named_table, write_concurrency: true])

    :ok
  end

  @doc "Forget every nonce whose window has passed by `now`, in Unix milliseconds."
  @spec forget_expired_nonces(integer()) :: :ok
  def forget_expired_nonces(now \\ System.system_time(:millisecond)) do
    if :ets.whereis(@nonces) != :undefined,
      do: :ets.select_delete(@nonces, [{{:_, :"$1"}, [{:"=<", :"$1", now}], [true]}])

    :ok
  end

  match _ do
    conn =
      conn
      |> assign(:boot, Owners.boot(owners(conn)))
      |> then(&put_resp_header(&1, LocusBackends.boot_header(), &1.assigns.boot))

    case {conn.method, LocusBackends.operation(conn.request_path)} do
      {"POST", {:ok, :health}} -> health(conn)
      {"POST", {:ok, :control}} -> control(conn, Listener.now(conn))
      {"POST", {:ok, :session}} -> session(conn, Listener.now(conn))
      _ -> refuse(closing(conn), :bad_request)
    end
  end

  defp owners(%Plug.Conn{assigns: %{service_opts: opts}}), do: Keyword.get(opts, :owners, Owners)

  defp key(%Plug.Conn{assigns: %{service_opts: opts}}) do
    case Keyword.get_lazy(opts, :key, &Locus.Config.backends_key/0) do
      key when byte_size(key) == 32 -> {:ok, key}
      _none -> :error
    end
  end

  # ————— health —————

  defp health(conn) do
    case read(conn, @max_health_bytes) do
      {:ok, body, conn} ->
        case LocusBackends.read_health(body) do
          :ok ->
            answer(
              conn,
              200,
              Jason.encode!(%{"version" => LocusBackends.version(), "release" => release()})
            )

          {:error, {:version, _presented} = error} ->
            refuse(conn, LocusBackends.refusal_for(error))

          {:error, _error} ->
            refuse(conn, :bad_request)
        end

      {:too_large, conn} ->
        refuse(conn, :too_large)

      {:unread, conn} ->
        refuse(conn, :bad_request)
    end
  end

  defp release, do: Prima.Version.current()

  # ————— control —————

  defp control(conn, now) do
    boot = conn.assigns.boot

    with {:ok, key} <- known(conn, key(conn)),
         {:ok, fields, body_hash} <- verified(conn, :control, key, now),
         :ok <- lifetime(conn, fields.boot in ["-", boot]),
         :ok <- sequence(conn, Owners.fresh(owners(conn), fields)),
         {:ok, body, conn} <- body(conn, LocusBackends.max_control_bytes()),
         :ok <- hashed(conn, :control, body_hash, body),
         {:ok, message} <- readable(conn, LocusBackends.read_control(body)),
         :ok <- named_lifetime(conn, message, fields.boot, boot),
         {:ok, answer} <- applied(conn, fields, message, open_env(key, fields, message, boot)) do
      case LocusBackends.encode_answer(message.type, answer) do
        {:ok, text} ->
          answer(conn, 200, text)

        {:error, {:too_large, :status_answer, _bytes, _max}} ->
          refuse(conn, :status_too_large)

        {:error, _unencodable} ->
          Logger.error("[Locus.Backends.Service] a #{message.type} answer did not encode")
          refuse(conn, :internal)
      end
    else
      {:refused, conn, refusal} -> refuse(conn, refusal)
    end
  end

  defp known(_conn, {:ok, key}), do: {:ok, key}
  defp known(conn, :error), do: {:refused, closing(conn), :unauthorized}

  defp verified(conn, kind, key, now) do
    with {:ok, header} <- Listener.auth_header(conn),
         {:ok, fields, body_hash} <- LocusBackends.verify_header(kind, key, header, now) do
      {:ok, fields, body_hash}
    else
      _refused -> {:refused, closing(conn), :unauthorized}
    end
  end

  defp lifetime(_conn, true), do: :ok
  defp lifetime(conn, false), do: {:refused, closing(conn), :stale_boot}

  defp sequence(_conn, :ok), do: :ok
  defp sequence(conn, {:error, code}), do: {:refused, closing(conn), code}

  defp body(conn, max) do
    case read(conn, max) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:too_large, conn} -> {:refused, conn, :too_large}
      {:unread, conn} -> {:refused, conn, :bad_request}
    end
  end

  defp hashed(conn, kind, body_hash, body) do
    case LocusBackends.verify_body(kind, body_hash, body) do
      :ok -> :ok
      {:error, :bad_mac} -> {:refused, conn, :unauthorized}
    end
  end

  defp readable(_conn, {:ok, message}), do: {:ok, message}
  defp readable(conn, {:error, error}), do: {:refused, conn, LocusBackends.refusal_for(error)}

  defp named_lifetime(conn, %{type: type}, named, boot) do
    if named == if(type == :hello, do: "-", else: boot),
      do: :ok,
      else: {:refused, conn, :stale_boot}
  end

  defp applied(conn, fields, message, open_env) do
    case Owners.control(owners(conn), fields, message, open_env) do
      {:ok, answer} -> {:ok, answer}
      {:error, code} -> {:refused, conn, code}
    end
  end

  # A sync's environment opened for its owner at the header's generation
  # and this lifetime, only once the owners find its version new.
  defp open_env(key, fields, %{type: :sync} = message, boot) do
    owner = %{
      athanor: message.owner.athanor,
      server: message.owner.server,
      generation: fields.generation,
      epoch: message.e
    }

    sealed = message.sealed

    fn ->
      with {:ok, text} <- LocusBackends.open(LocusBackends.seal_key(key), owner, boot, sealed),
           {:ok, %{} = env} <- Jason.decode(text) do
        {:ok, env}
      else
        _ -> :error
      end
    end
  end

  defp open_env(_key, _fields, _message, _boot), do: nil

  # ————— sessions —————

  defp session(conn, now) do
    with {:ok, key} <- known(conn, key(conn)),
         {:ok, invoke, body_hash} <- verified(conn, :invoke, key, now),
         :ok <- lifetime(conn, invoke.boot == conn.assigns.boot),
         :ok <- owner(closing(conn), invoke),
         :ok <- nonce(closing(conn), invoke, now, false),
         {:ok, body, conn} <- body(conn, LocusBackends.max_session_bytes()),
         :ok <- hashed(conn, :invoke, body_hash, body),
         :ok <- owner(conn, invoke),
         :ok <- nonce(conn, invoke, now, true),
         {:ok, message} <- readable(conn, LocusBackends.read_session(body)),
         :ok <- named(conn, message, invoke),
         {:ok, answer} <- served(conn, invoke, message) do
      case LocusBackends.encode_session_answer(message.type, answer) do
        {:ok, text} ->
          answer(conn, 200, text)

        {:error, _unencodable} ->
          Logger.error("[Locus.Backends.Service] a #{message.type} answer did not encode")
          refuse(conn, :internal)
      end
    else
      {:refused, conn, refusal} -> refuse(conn, refusal)
    end
  end

  defp owner(conn, invoke) do
    case Owners.admit(owners(conn), invoke) do
      :ok -> :ok
      {:error, code} -> {:refused, conn, code}
    end
  end

  # A session message names the owner and epoch its signature names.
  defp named(conn, %{owner: owner, e: e}, invoke) do
    if owner == %{athanor: invoke.athanor, server: invoke.server} and e == invoke.epoch,
      do: :ok,
      else: {:refused, conn, :bad_request}
  end

  defp served(conn, invoke, %{type: :open} = message) do
    case Owners.open(owners(conn), invoke, message) do
      {:ok, answer} -> {:ok, answer}
      {:error, code} -> {:refused, conn, code}
    end
  end

  defp served(conn, invoke, message) do
    case Owners.session(owners(conn), invoke, message.session) do
      {:ok, pid, _secrets} -> reach(conn, pid, message)
      {:error, code} -> {:refused, conn, code}
    end
  end

  # A session whose process record is gone has ended and holds no line.
  defp reach(_conn, nil, %{type: :send}), do: {:ok, %{status: :ended}}
  defp reach(_conn, nil, %{type: :close}), do: {:ok, %{status: :closed}}
  defp reach(_conn, nil, %{type: :recv}), do: {:ok, %{lines: [], dropped: 0, running: false}}

  defp reach(conn, pid, message) do
    case message.type do
      :send -> {:ok, %{status: Backend.send_lines(pid, message.lines)}}
      :recv -> {:ok, Backend.recv(pid, message.after, message.max_wait_ms)}
      :close -> with :ok <- Backend.close(pid), do: {:ok, %{status: :closed}}
    end
  catch
    :exit, _reason -> reach(conn, nil, message)
  end

  # ————— nonces —————

  # A nonce is held for as long as its header could verify: until its `ts`
  # and the window. `record?` records it, only once the body was the one
  # its header signed.
  defp nonce(conn, invoke, now, record?) do
    row = {invoke.athanor, invoke.server, invoke.generation, invoke.epoch, invoke.nonce}

    with :ok <- unseen(row, now),
         :ok <- room(invoke, now),
         :ok <- if(record?, do: record(row, invoke.ts, now), else: :ok) do
      :ok
    else
      {:error, code} -> {:refused, conn, code}
    end
  end

  defp unseen(row, now) do
    case :ets.lookup(@nonces, row) do
      [{^row, expires}] when expires > now -> {:error, :replay}
      _ -> :ok
    end
  end

  defp room(invoke, now) do
    owner = {invoke.athanor, invoke.server, invoke.generation, invoke.epoch, :_}
    live = [{{owner, :"$1"}, [{:>, :"$1", now}], [true]}]

    if :ets.select_count(@nonces, live) < LocusBackends.max_nonces() do
      :ok
    else
      :ets.select_delete(@nonces, [{{owner, :"$1"}, [{:"=<", :"$1", now}], [true]}])
      {:error, :nonce_cache_full}
    end
  end

  defp record(row, ts, now) do
    :ets.select_delete(@nonces, [{{row, :"$1"}, [{:"=<", :"$1", now}], [true]}])

    if :ets.insert_new(@nonces, {row, ts + LocusBackends.nonce_window_ms()}),
      do: :ok,
      else: {:error, :replay}
  end

  # ————— bodies and answers —————

  # The declared length first, so a body past the bound is refused without
  # a byte of it read; then the read itself, bounded for a body that
  # declares none.
  defp read(conn, max) do
    case Listener.read_bounded(conn, max, true) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:too_large, conn, _past} -> {:too_large, closing(conn)}
      {:unread, conn} -> {:unread, closing(conn)}
    end
  end

  # A refusal made before the body is read, or with the body unread past
  # its bound, closes the connection: the body is never read.
  defp closing(conn), do: put_resp_header(conn, "connection", "close")

  defp refuse(conn, refusal) do
    Logger.warning(
      "[Locus.Backends.Service] #{conn.method} refused: #{LocusBackends.code(refusal)}"
    )

    answer(conn, LocusBackends.status(refusal), LocusBackends.encode_refusal(refusal))
  end

  defp answer(conn, status, body) do
    conn
    |> put_resp_content_type(@json)
    |> send_resp(status, body)
  end
end
