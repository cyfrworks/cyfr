# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.TinctureDataController do
  @moduledoc """
  The tincture data routes, `Prima.TinctureWire`'s endpoint side:

      POST /_f/v1/invoke               — run a component the tincture declares
      POST /_f/v1/action               — run a system action the tincture declares
      GET  /_f/v1/socket               — an app's stream connection
      GET  /_f/v1/o/:frame_id/socket   — a canvas's stream connection

  A connection's upgrade admits nothing here: it is handed to its socket
  (`Emissary.Web.FrameSocket`), which admits each subscription it carries.

  ## Who is asking

  A frame presents its per-open credential as a bearer and nothing else,
  established with the version it opened and the grant it opened under
  (`Emissary.Web.FrameAdmission.frame/3`): a bearer copied out of its
  frame carries exactly that authority and nothing wider.

  A public tincture's page names the tincture as `public` and presents no
  bearer: it is admitted only for a tincture that is public, under the
  address's public context (`Sanctum.TinctureAccess`), and never under a
  viewer's session — no route here reads a cookie. A request with neither
  is refused as `no_frame`; one with both is refused unread.

  ## What it may reach

  Under that grant, the tincture's declaration bounds what it reaches:
  an invoke names a component among its `dependencies.static`
  (`Compendium.tincture_invokes?/2`) and an action one of its `actions`.
  Anything else is refused before dispatch. An admitted invoke runs
  through the gate's `tincture` operation (`invoke_protected` for a frame,
  `invoke_public` for a public page) with the input
  `{"operation": …, "params": …}`; an action through the gate under the
  frame's context. A read is admitted only when what it carries may flow
  to every origin the frame connects to (`Emissary.Web.FrameAdmission.flowing/2`).

  A canvas (a tincture that declares the `tincture.desktop` block) invokes
  no component and runs no operation, whatever its declaration names:
  these routes refuse its frame's credential `forbidden`
  (`canvas_path_required`). It reads its streams over its own stream
  connection alone.

  ## Limits

  Each request is charged the invocation rate of its frame credential, or
  of a public page's address and tincture
  (`Emissary.Web.FrameAdmission.charge/1`), refused over its bound with a
  typed refusal.

  Every answer, a refusal included, is the wire's own shape; a refusal
  made here is the request's one recorded decision
  (`CyfrWeb.Plugs.CallIdentity`), and a refusal the gate made is the
  gate's.
  """

  use Emissary.Web, :controller

  @behaviour CyfrWeb.ErrorRenderer

  alias CyfrWeb.Plugs.CallIdentity
  alias Emissary.Web.{FrameAdmission, FrameSocket}
  alias Prima.TinctureWire

  @doc "Run a component the tincture declares."
  @spec invoke(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def invoke(conn, _params), do: handle(conn, :invoke)

  @doc "Run a system action the tincture declares."
  @spec system_action(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def system_action(conn, _params), do: handle(conn, :action)

  @doc "Upgrade to an app's stream connection."
  @spec socket(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def socket(conn, _params), do: upgrade(conn, :shared)

  @doc "Upgrade to the stream connection of the canvas open the path's `frame_id` names."
  @spec canvas_socket(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def canvas_socket(conn, %{"frame_id" => frame_id}), do: upgrade(conn, {:canvas, frame_id})

  # A request that is no WebSocket upgrade is refused in the wire's shape.
  defp upgrade(conn, path) do
    case WebSockAdapter.UpgradeValidation.validate_upgrade(conn) do
      :ok -> FrameSocket.upgrade(conn, path)
      {:error, sentence} -> refuse(conn, Prima.Refusal.classify({:invalid_argument, sentence}))
    end
  end

  # ---------------------------------------------------------------------------
  # The wire's refusal, as a renderer
  # ---------------------------------------------------------------------------

  @doc """
  Render `reason` as the wire's refusal, at `status`, as a refusal made
  before the gate: recorded once as the request's decision
  (`CyfrWeb.Plugs.CallIdentity.refused/2`). The pipeline's rate limit
  renders through it, so a throttled frame reads the same shape.
  """
  @impl true
  def send(%Plug.Conn{} = conn, status, reason, _message) do
    refusal = %{Sanctum.Refusals.classify(reason) | stage: :admission}

    conn
    |> CallIdentity.refused(refusal)
    |> answer(status, refusal)
  end

  @doc "Render `reason` as `send/4` does and halt the pipeline."
  @impl true
  def halt(%Plug.Conn{} = conn, status, reason, message) do
    conn
    |> __MODULE__.send(status, reason, message)
    |> Plug.Conn.halt()
  end

  defp answer(conn, status, %Prima.Refusal{} = refusal) do
    conn
    |> retry_after(refusal.reason)
    |> challenge(status)
    |> put_status(status)
    |> json(TinctureWire.refusal(refusal))
  end

  # A refusal made here, before the gate.
  defp refuse(conn, %Prima.Refusal{} = refusal),
    do: __MODULE__.send(conn, CyfrWeb.ApiError.status(refusal.class), refusal, nil)

  # A refusal the gate made and recorded.
  defp refused_by_gate(conn, reason) do
    refusal = Sanctum.Refusals.classify(reason)

    conn
    |> CallIdentity.decided()
    |> answer(CyfrWeb.ApiError.status(refusal.class), refusal)
  end

  defp retry_after(conn, {:rate_limited, seconds}) when is_integer(seconds),
    do: put_resp_header(conn, "retry-after", Integer.to_string(seconds))

  defp retry_after(conn, _reason), do: conn

  # RFC 9110 §15.5.2: a 401 MUST carry at least one challenge.
  defp challenge(conn, 401), do: put_resp_header(conn, "www-authenticate", "Bearer")
  defp challenge(conn, _status), do: conn

  # ---------------------------------------------------------------------------
  # Admission
  # ---------------------------------------------------------------------------

  defp handle(conn, kind) do
    case admit(conn, kind) do
      {:ok, conn, request, caller} -> dispatch(conn, kind, request, caller)
      {:error, conn, refusal} -> refuse(conn, refusal)
    end
  end

  # In order: the body, who is asking, where it may ask, the charge, the
  # grant, then whether what the read may carry may reach every origin
  # the frame connects to. The charge follows the caller, so a frame's
  # undeclared attempts count against it too.
  defp admit(conn, kind) do
    with {:ok, request} <- decode(conn, kind),
         {:ok, caller} <- caller(conn, request) do
      conn = assign(conn, :context, caller.ctx)

      with :ok <- placed(caller),
           :ok <- FrameAdmission.charge(caller),
           :ok <- granted(kind, request, caller),
           :ok <- FrameAdmission.flowing(read(kind, request), caller) do
        {:ok, conn, request, caller}
      else
        {:error, refusal} -> {:error, conn, refusal}
      end
    else
      {:error, refusal} -> {:error, conn, refusal}
    end
  end

  defp decode(conn, kind) do
    case TinctureWire.decode_request(kind, conn.body_params) do
      {:ok, request} -> {:ok, request}
      {:error, sentence} -> {:error, Prima.Refusal.classify({:invalid_argument, sentence})}
    end
  end

  defp caller(conn, request) do
    case {bearer(conn), Map.get(request, :public)} do
      {{:ok, bearer}, nil} ->
        with {:ok, caller} <- FrameAdmission.frame(bearer, Sanctum.ClientIp.resolve(conn)) do
          {:ok, %{caller | ctx: CallIdentity.stamp(conn, caller.ctx)}}
        end

      {:none, %{} = public} ->
        public_caller(conn, public)

      {:none, nil} ->
        {:error, FrameAdmission.no_frame()}

      {:invalid, _public} ->
        {:error, Prima.Refusal.classify(:invalid_credential)}

      {{:ok, _bearer}, %{}} ->
        {:error,
         Prima.Refusal.classify(
           {:invalid_argument,
            "A request carries a frame credential or names a public tincture, not both"}
         )}
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, TinctureWire.bearer_header()) do
      [] ->
        :none

      [value] ->
        case TinctureWire.read_bearer(value) do
          {:ok, bearer} -> {:ok, bearer}
          :error -> :invalid
        end

      _several ->
        :invalid
    end
  end

  # A public tincture's page: the tincture must be public in the athanor
  # its address names, and nothing runs under anything but that
  # address's public context.
  defp public_caller(conn, %{athanor: athanor, publisher: publisher, name: name}) do
    client_ip = Sanctum.ClientIp.resolve(conn)

    with {:ok, public_ctx} <- Sanctum.TinctureAccess.public_context(athanor),
         {:ok, tincture} <- Sanctum.TinctureAccess.get_public(public_ctx, publisher, name),
         {:ok, declaration} <- FrameAdmission.declaration(tincture.manifest) do
      ctx = FrameAdmission.interactive(CallIdentity.stamp(conn, public_ctx))

      {:ok,
       %{
         ctx: %{ctx | client_ip: client_ip},
         route: :public,
         address: athanor,
         tincture: %{publisher: publisher, name: name},
         manifest: tincture.manifest,
         declaration: declaration,
         rate_key: {:public, public_ctx.athanor_id, publisher, name, client_ip}
       }}
    else
      {:error, %Prima.Refusal{} = refusal} ->
        {:error, refusal}

      {:error, :unavailable} ->
        {:error, Prima.Refusal.classify(:unavailable)}

      {:error, _absent_or_private} ->
        {:error, Prima.Refusal.classify({:not_found, "Tincture", "#{publisher}/#{name}"})}
    end
  end

  # A canvas invokes and runs nothing: its frame reaches no route here.
  defp placed(%{route: :protected, declaration: declaration}) do
    if FrameAdmission.canvas?(declaration),
      do: {:error, FrameAdmission.canvas_path_required()},
      else: :ok
  end

  defp placed(%{route: :public}), do: :ok

  # ---------------------------------------------------------------------------
  # The grant: the tincture's declaration
  # ---------------------------------------------------------------------------

  defp granted(:invoke, %{ref: ref}, %{manifest: manifest}) do
    if Compendium.tincture_invokes?(manifest, ref),
      do: :ok,
      else: {:error, FrameAdmission.undeclared(:component)}
  end

  defp granted(:action, %{operation: operation}, %{declaration: declaration}) do
    if operation in declaration.actions,
      do: :ok,
      else: {:error, FrameAdmission.undeclared(:action)}
  end

  defp read(:invoke, _request), do: :invoke
  defp read(:action, %{operation: operation}), do: {:action, operation}

  # ---------------------------------------------------------------------------
  # Dispatch
  # ---------------------------------------------------------------------------

  defp dispatch(conn, :invoke, request, caller) do
    %{publisher: publisher, name: name} = caller.tincture

    args =
      %{
        "publisher" => publisher,
        "tincture_name" => name,
        "reference" => request.ref,
        "input" => %{"operation" => request.operation, "params" => request.args}
      }
      |> Map.merge(route_args(caller))

    call(conn, caller.ctx, "tincture", args)
  end

  defp dispatch(conn, :action, %{operation: operation, args: args}, caller) do
    [tool, action] = String.split(operation, ".", parts: 2)
    call(conn, caller.ctx, tool, Map.put(args, "action", action))
  end

  # The route fixes the profile the run roots at: a frame's is the
  # tincture's owner profile in its own athanor, a public page's the
  # public profile the address names.
  defp route_args(%{route: :public, address: address}),
    do: %{"action" => "invoke_public", "athanor" => address}

  defp route_args(%{route: :protected}), do: %{"action" => "invoke_protected"}

  # The gate authorizes, casts and records the call under the request's
  # own call id; its refusal is its row.
  defp call(conn, ctx, tool, args) do
    case Sanctum.Gate.call_external(tool, ctx, args, call_id: ctx.call_id) do
      {:ok, result} -> json(conn, TinctureWire.result(result))
      {:error, reason} -> refused_by_gate(conn, reason)
    end
  end
end
