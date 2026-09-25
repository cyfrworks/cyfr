# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.CallIdentity do
  @moduledoc """
  The identity of a request at an admission entry, minted before its
  first check.

  The first plug of every pipeline that admits work — `/mcp`, the
  authenticated API, the tincture routes and the webhook route — mints
  the request's correlation id (`req_…`, `Prima.UUID7.request_id/0`) and
  the admission's call id (`call_…`, `Prima.UUID7.generate_id/1`), assigns
  both, sets the request id on the log lines and answers it in
  `x-request-id`. A client's own `x-request-id` is never read: identity
  is server-minted, so a row in the decision log names a request this
  server saw and not one a caller labelled.

  `EmissaryWeb.Plugs.Authenticate` stamps both ids on the context it
  builds (`stamp/2`); an entry that builds its own context does the same.
  The gate takes the call id as its own (`Grimoire.call_external/4`'s
  `:call_id`), so the decision it records and the row the transport
  answered share one identity.

  ## One append per refusal

  A refusal an entry renders before the gate — a plug's, a controller's —
  goes through `EmissaryWeb.MCPError` or `EmissaryWeb.ApiError`, which
  record it here (`refused/2`) exactly once per request: under the minted
  call id, with the context's actor when the pipeline had established
  one and none otherwise, and with the operation's names when the request
  said them. The gate's own refusal is the gate's row: a controller that
  renders a gate result marks the request decided first (`decided/1`),
  and the renderer appends nothing. A request outside these pipelines
  carries no call id and records nothing: an error before routing, a
  sign-in throttle, a page nobody defined are not admission entries.

  ## Options

  - `:tool` — the operation the pipeline's routes admit, for the names a
    pre-gate refusal is recorded under; the action is the route's. Without
    it the names are read off a JSON-RPC body (`tools/call`'s `name` and
    `arguments.action`), which is how `/mcp` names them.
  """

  @behaviour Plug

  import Plug.Conn

  alias Sanctum.Context

  @impl true
  def init(opts), do: Keyword.validate!(opts, [:tool])

  @impl true
  def call(conn, opts) do
    conn
    |> mint()
    |> assign(:call_tool, Keyword.get(opts, :tool))
  end

  @doc """
  Mint the request id and the call id onto `conn`: assigned, on the log
  lines, and answered in `x-request-id`. An entry that decides before any
  pipeline — the endpoint's ownership plug refusing — mints here too.
  """
  @spec mint(Plug.Conn.t()) :: Plug.Conn.t()
  def mint(%Plug.Conn{} = conn) do
    request_id = Prima.UUID7.request_id()
    call_id = Prima.UUID7.generate_id("call")
    Prima.LoggerContext.set_request_id(request_id)

    conn
    |> assign(:request_id, request_id)
    |> assign(:call_id, call_id)
    |> put_resp_header("x-request-id", request_id)
  end

  @doc """
  The context carrying the request's identity: its `request_id` and
  `call_id` when the pipeline minted them, its own otherwise.
  """
  @spec stamp(Plug.Conn.t(), Context.t()) :: Context.t()
  def stamp(%Plug.Conn{assigns: assigns}, %Context{} = ctx) do
    %{
      ctx
      | request_id: Map.get(assigns, :request_id) || ctx.request_id,
        call_id: Map.get(assigns, :call_id) || ctx.call_id
    }
  end

  @doc """
  Record `reason` — a `%Prima.Refusal{}`, a reason term or a JSON-RPC
  code name — as the request's refused decision, once: a request that
  minted no call id, or whose decision was already recorded, is returned
  unchanged. Always answers the conn; audit never decides the refusal.
  """
  @spec refused(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def refused(%Plug.Conn{assigns: %{call_id: call_id} = assigns} = conn, reason)
      when is_binary(call_id) do
    if Map.get(assigns, :decision_recorded, false) do
      conn
    else
      ctx = context(assigns)
      {tool, action} = names(conn)

      decision =
        Grimoire.refused_decision(ctx, reason,
          call_id: call_id,
          request_id: Map.get(assigns, :request_id),
          plane: :external,
          tool: tool,
          action: action
        )

      Grimoire.open_decision(ctx, decision, %{method: method(conn), input: %{}})
      decided(conn)
    end
  end

  def refused(%Plug.Conn{} = conn, _reason), do: conn

  @doc """
  Mark the request's decision recorded — by the gate, whose result the
  caller is about to render — so the renderer appends nothing.
  """
  @spec decided(Plug.Conn.t()) :: Plug.Conn.t()
  def decided(%Plug.Conn{} = conn), do: assign(conn, :decision_recorded, true)

  defp context(%{context: %Context{} = ctx}), do: ctx
  defp context(_assigns), do: nil

  # The names the request said: the pipeline's tool with the route's
  # action, or a JSON-RPC body's tool call.
  defp names(%Plug.Conn{assigns: %{call_tool: tool}} = conn) when is_binary(tool),
    do: {tool, route_action(conn)}

  defp names(%Plug.Conn{body_params: %{"method" => "tools/call", "params" => params}})
       when is_map(params) and not is_struct(params) do
    action =
      case Map.get(params, "arguments") do
        %{"action" => action} -> string(action)
        _other -> nil
      end

    {string(Map.get(params, "name")), action}
  end

  defp names(_conn), do: {nil, nil}

  defp route_action(%Plug.Conn{private: %{phoenix_action: action}}) when is_atom(action),
    do: Atom.to_string(action)

  defp route_action(_conn), do: nil

  # The wire method the request-log row records: a JSON-RPC method, or
  # the HTTP method and path.
  defp method(%Plug.Conn{body_params: %{"method" => method}}) when is_binary(method), do: method
  defp method(%Plug.Conn{method: verb, request_path: path}), do: verb <> " " <> path

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil
end
