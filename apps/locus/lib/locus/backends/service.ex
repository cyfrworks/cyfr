# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.Service do
  @max_health_bytes 4096
  @tools_ttl_ms 60_000

  @moduledoc """
  The backends service: the listener side of `Prima.LocusBackends`, and
  the only thing that reaches `Locus.Backends.Owners` from outside. Three
  `POST` routes; whatever is not one of them is refused `bad_request`, and
  every refusal is `Prima.LocusBackends.encode_refusal/1` at its code's
  status. Every answer carries `x-cyfr-boot`, the service's lifetime
  (`Locus.Backends.Owners.boot/1`).

  ## Health

  `POST /locus/v1/backends/health` answers without authentication: a
  `{"version": 1}` body, read within #{@max_health_bytes} bytes, is
  answered with the protocol version and the release.

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

  ## An MCP request, in order

  Every answer carries `mcp-protocol-version` and the request's
  `x-request-id` (one is minted for a request without one).

  1. **The header**, verified under the key of the owner it names:
     `unauthorized` is JSON-RPC `-33001` at 401.
  2. **The lifetime**: the header's `boot` must be this service's, else
     `stale_boot`.
  3. **The owner**, at exactly the header's generation and epoch
     (`Locus.Backends.Owners.admit/2`): `unknown_owner`, `stale_epoch`,
     `epoch_ahead`, `lapsed`.
  4. **The nonce**: one seen at this owner version within its window is
     `replay`; an owner version holding `max_nonces/0` live nonces is
     `nonce_cache_full` (503).
  5. **The body**, read within `max_mcp_bytes/0` (JSON-RPC `-32600` at
     413), must be the one the header hashed (`-33001` at 401).
  6. **The owner and the nonce again**, and the nonce recorded: only a
     request whose body was the one signed records one.
  7. **The message**: not JSON is `-32700`, not one object `-32600`, both
     at 400; one without an `id` is a notification, answered `202`.
  8. **Conformance**: the `mcp-protocol-version` header and the body's
     `_meta` version present, equal and this revision (`-32020`, or
     `-32022` naming the supported revision), the client capabilities
     present (`-32602`), `mcp-method` naming the body's method and, for
     `tools/call`, `mcp-name` its tool (`-32020`), all at 400.
  9. **The method**: `server/discover`, `tools/list` (the owner's tools,
     each `<backend>__<tool>`) and `tools/call`; any other is `-32601` at
     404. A tool the backend refuses is an `isError` result; a fault of
     this service's is `-32603` at 500.

  Every refusal made before the body is read closes the connection, so
  the body is never read. Everything an owner's backends produce is
  masked with the owner's secret values before it leaves. Nothing a
  request carries is logged: a refusal is logged by its code.
  """

  use Plug.Router, copy_opts_to_assign: :service_opts

  require Logger

  alias Locus.Backends.{Backend, Owners}
  alias Prima.LocusBackends
  alias Prima.MCP.Protocol, as: MCPProtocol

  @nonces __MODULE__.Nonces
  @json "application/json"
  @server_name "cyfr-locus"

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
      {"POST", {:ok, :control}} -> control(conn, now(conn))
      {"POST", {:ok, :mcp}} -> mcp(conn, now(conn))
      {_method, {:ok, :mcp}} -> not_allowed(conn)
      _ -> refuse(closing(conn), :bad_request)
    end
  end

  defp owners(%Plug.Conn{assigns: %{service_opts: opts}}), do: Keyword.get(opts, :owners, Owners)

  # The clock a header's window and a nonce's expiry are read against: the
  # system's, or the `:now` this plug was given (a test presenting the shared
  # vectors' headers at the vectors' instant).
  defp now(%Plug.Conn{assigns: %{service_opts: opts}}) do
    case Keyword.fetch(opts, :now) do
      {:ok, now} when is_function(now, 0) -> now.()
      :error -> System.system_time(:millisecond)
    end
  end

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
        case Jason.decode(body) do
          {:ok, %{"version" => 1} = wire} when map_size(wire) == 1 ->
            answer(
              conn,
              200,
              Jason.encode!(%{"version" => LocusBackends.version(), "release" => release()})
            )

          {:ok, %{"version" => version}} when version != 1 ->
            refuse(conn, LocusBackends.refusal_for({:version, version}))

          {:ok, %{} = wire} when not is_map_key(wire, "version") ->
            refuse(conn, LocusBackends.refusal_for({:version, nil}))

          _ ->
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
    with [header] <- get_req_header(conn, LocusBackends.auth_header()),
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

  # ————— MCP —————

  defp mcp(conn, now) do
    request_id =
      case get_req_header(conn, "x-request-id") do
        [id | _] when id != "" -> id
        _ -> request_id()
      end

    conn =
      conn
      |> put_resp_header(MCPProtocol.protocol_version_header(), MCPProtocol.version())
      |> put_resp_header("x-request-id", request_id)

    with {:ok, key} <- rpc_key(conn),
         {:ok, invoke, body_hash} <- rpc_verified(conn, key, now),
         :ok <- lifetime(conn, invoke.boot == conn.assigns.boot),
         {:ok, _backends} <- owner(closing(conn), invoke),
         :ok <- nonce(closing(conn), invoke, now, false),
         {:ok, body, conn} <- rpc_body(conn),
         :ok <- rpc_hashed(conn, body_hash, body),
         {:ok, owner} <- owner(conn, invoke),
         :ok <- nonce(conn, invoke, now, true),
         {:ok, message} <- rpc_message(conn, body) do
      rpc(conn, owner, message)
    else
      {:refused, conn, refusal} -> refuse(conn, refusal)
      {:rpc, conn, status, code, text} -> rpc_error(conn, status, nil, code, text)
    end
  end

  defp request_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    [<<a::32>>, <<b::16>>, <<c::16>>, <<d::16>>, <<e::48>>]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end

  defp rpc_key(conn) do
    case key(conn) do
      {:ok, key} -> {:ok, key}
      :error -> unauthorized(conn)
    end
  end

  defp rpc_verified(conn, key, now) do
    with [header] <- get_req_header(conn, LocusBackends.auth_header()),
         {:ok, invoke, body_hash} <- LocusBackends.verify_header(:invoke, key, header, now) do
      {:ok, invoke, body_hash}
    else
      _refused -> unauthorized(conn)
    end
  end

  # Refused before its body is read, the connection closes; with the body
  # read and not the one signed, it need not.
  defp unauthorized(conn, body \\ :unread) do
    Logger.warning("[Locus.Backends.Service] an MCP request refused: unauthorized")
    conn = if body == :unread, do: closing(conn), else: conn
    {:rpc, conn, 401, -33_001, "unauthorized"}
  end

  defp owner(conn, invoke) do
    case Owners.admit(owners(conn), invoke) do
      {:ok, owner} -> {:ok, owner}
      {:error, code} -> {:refused, conn, code}
    end
  end

  defp rpc_body(conn) do
    case read(conn, LocusBackends.max_mcp_bytes()) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:too_large, conn} -> {:rpc, conn, 413, -32_600, "Request body too large"}
      {:unread, conn} -> {:rpc, conn, 400, -32_600, "The request body could not be read"}
    end
  end

  defp rpc_hashed(conn, body_hash, body) do
    case LocusBackends.verify_body(:invoke, body_hash, body) do
      :ok -> :ok
      {:error, :bad_mac} -> unauthorized(conn, :read)
    end
  end

  defp rpc_message(conn, body) do
    case Jason.decode(body) do
      {:ok, %{} = message} ->
        {:ok, message}

      {:ok, _other} ->
        # One JSON-RPC request or notification; a batch has no handler.
        {:rpc, conn, 400, -32_600, "Expected a single JSON-RPC message"}

      {:error, _} ->
        {:rpc, conn, 400, -32_700, "Parse error: body is not valid JSON"}
    end
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

  # ————— JSON-RPC —————

  defp rpc(conn, owner, message) do
    if Map.has_key?(message, "id") do
      id = message["id"]

      case conformance(conn, message) do
        nil -> method(conn, owner, message, id)
        {code, text, data} -> rpc_error(conn, 400, id, code, text, data)
      end
    else
      # A notification: answered, with nothing to answer.
      send_resp(conn, 202, "")
    end
  end

  defp method(conn, owner, message, id) do
    case handle(owner, message) do
      {:ok, result} ->
        result = LocusBackends.mask(result, owner.secrets)
        body = %{"jsonrpc" => "2.0", "id" => id, "result" => stamp(result)}
        answer(conn, 200, Jason.encode!(body))

      {:unknown, method} ->
        # 404, not 400: a client that speaks both eras reads the status to
        # tell a modern server missing one method from a legacy server
        # missing the endpoint.
        rpc_error(conn, 404, id, -32_601, "unsupported method: #{spell(method)}")

      {:refused, text} ->
        error = %{"code" => -32_603, "message" => LocusBackends.mask(text, owner.secrets)}
        answer(conn, 200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "error" => error}))
    end
  rescue
    exception ->
      Logger.error(
        "[Locus.Backends.Service] an MCP request failed: " <>
          Prima.LoggerContext.shape(exception)
      )

      rpc_error(conn, 500, id, -32_603, "internal error")
  end

  defp handle(_owner, %{"method" => "server/discover"}) do
    {:ok,
     %{
       "supportedVersions" => MCPProtocol.supported(),
       "capabilities" => %{"tools" => %{"listChanged" => false}, "extensions" => %{}},
       "instructions" =>
         "Runs this server's stdio MCP backends; every backend tool appears as " <>
           "`<backend>__<tool>`.",
       "ttlMs" => @tools_ttl_ms,
       "cacheScope" => "private"
     }}
  end

  defp handle(owner, %{"method" => "tools/list"}),
    do: {:ok, %{"tools" => tools(owner), "ttlMs" => @tools_ttl_ms, "cacheScope" => "private"}}

  defp handle(owner, %{"method" => "tools/call"} = message) do
    case message["params"] do
      %{"name" => name} = params when is_binary(name) and name != "" ->
        {:ok, call(owner, name, params["arguments"])}

      _ ->
        {:refused, "tools/call: missing 'name'"}
    end
  end

  defp handle(_owner, message), do: {:unknown, message["method"]}

  # A ready or idle backend's catalogue, as it last listed it, each tool
  # named for its backend.
  defp tools(owner) do
    for {backend, pid} <- owner.backends, pid != nil, tool <- listed(pid) do
      description =
        case tool["description"] do
          text when is_binary(text) and text != "" -> "[#{backend}] #{text}"
          _ -> "[#{backend}]"
        end

      %{
        "name" => "#{backend}__#{tool["name"]}",
        "description" => description,
        "inputSchema" => tool["inputSchema"] || %{"type" => "object"}
      }
    end
  end

  defp listed(pid) do
    for %{} = tool <- Backend.list_tools(pid), do: tool
  catch
    :exit, _reason -> []
  end

  # A tool's answer, or its refusal as a tool's error.
  defp call(owner, name, arguments) do
    with [backend, tool] when backend != "" <- String.split(name, "__", parts: 2),
         {^backend, pid} <- List.keyfind(owner.backends, backend, 0) do
      called(backend, pid, tool, arguments)
    else
      _ -> tool_error("unknown tool: #{name}")
    end
  end

  defp called(backend, nil, _tool, _arguments),
    do: tool_error("backend '#{backend}' not ready: spawning")

  defp called(_backend, pid, tool, arguments) do
    case Backend.call_tool(pid, tool, arguments) do
      {:ok, %{} = result} -> result
      {:ok, _other} -> %{}
      {:error, {:tool_error, text}} -> tool_error(text)
    end
  catch
    :exit, _reason -> tool_error("tool call failed")
  end

  defp tool_error(text),
    do: %{"content" => [%{"type" => "text", "text" => text}], "isError" => true}

  # Every result declares its type and this service's identity.
  defp stamp(result) do
    meta =
      case result["_meta"] do
        %{} = meta -> meta
        _ -> %{}
      end

    info = %{"name" => @server_name, "version" => release()}

    result
    |> Map.put("resultType", MCPProtocol.result_type(:complete))
    |> Map.put("_meta", Map.put(meta, MCPProtocol.meta_server_info_key(), info))
  end

  # The per-request checks that replace the handshake: nil when the request
  # is well formed, or the JSON-RPC error to answer with.
  defp conformance(conn, message) do
    meta =
      case message do
        %{"params" => %{"_meta" => %{} = meta}} -> meta
        _ -> %{}
      end

    header = header(conn, MCPProtocol.protocol_version_header())
    declared = meta[MCPProtocol.meta_protocol_version_key()]
    version = MCPProtocol.version()

    cond do
      header == nil ->
        {-32_020, "Missing required MCP-Protocol-Version header.", nil}

      declared in [nil, "", false] ->
        {-32_020, "Missing required #{MCPProtocol.meta_protocol_version_key()} in params._meta.",
         nil}

      header != declared ->
        {-32_020,
         "MCP-Protocol-Version header (#{header}) does not match " <>
           "#{MCPProtocol.meta_protocol_version_key()} (#{spell(declared)}).", nil}

      header != version ->
        {-32_022, "Unsupported protocol version #{header}.",
         %{"supported" => MCPProtocol.supported(), "requested" => header}}

      not (is_map(meta[MCPProtocol.meta_client_capabilities_key()]) or
               is_list(meta[MCPProtocol.meta_client_capabilities_key()])) ->
        {-32_602,
         "Missing required #{MCPProtocol.meta_client_capabilities_key()} in params._meta.", nil}

      header(conn, MCPProtocol.method_header()) != message["method"] ->
        {-32_020,
         "Mcp-Method header (#{header(conn, MCPProtocol.method_header()) || "absent"}) " <>
           "does not match the request body.", nil}

      true ->
        subject(conn, message)
    end
  end

  # `tools/call` names its subject in `params.name`; this service serves no
  # resources or prompts, so nothing else names one.
  defp subject(conn, %{"method" => "tools/call", "params" => %{"name" => name}})
       when is_binary(name) do
    named =
      case header(conn, MCPProtocol.name_header()) do
        nil ->
          nil

        value ->
          case MCPProtocol.decode_header_value(value) do
            {:ok, decoded} -> decoded
            :error -> nil
          end
      end

    if named == name,
      do: nil,
      else:
        {-32_020, "Mcp-Name header (#{named || "absent"}) does not match the request body.", nil}
  end

  defp subject(_conn, _message), do: nil

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp spell(value) when is_binary(value), do: value
  defp spell(value), do: Jason.encode!(value)

  defp not_allowed(conn) do
    conn
    |> put_resp_header(MCPProtocol.protocol_version_header(), MCPProtocol.version())
    |> put_resp_header("allow", "POST")
    |> closing()
    |> rpc_error(405, nil, -32_600, "#{conn.method} is not supported on the MCP endpoint.")
  end

  defp rpc_error(conn, status, id, code, text, data \\ nil) do
    error = %{"code" => code, "message" => text}
    error = if data == nil, do: error, else: Map.put(error, "data", data)
    answer(conn, status, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "error" => error}))
  end

  # ————— bodies and answers —————

  # The declared length first, so a body past the bound is refused without
  # a byte of it read; then the read itself, bounded for a body that
  # declares none.
  defp read(conn, max) do
    with :ok <- declared(conn, max) do
      case read_body(conn, length: max, read_length: max) do
        {:ok, body, conn} -> {:ok, body, conn}
        {:more, _head, conn} -> {:too_large, closing(conn)}
        {:error, _reason} -> {:unread, closing(conn)}
      end
    end
  end

  defp declared(conn, max) do
    with [text] <- get_req_header(conn, "content-length"),
         {bytes, ""} when bytes > max <- Integer.parse(text) do
      {:too_large, closing(conn)}
    else
      _ -> :ok
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
