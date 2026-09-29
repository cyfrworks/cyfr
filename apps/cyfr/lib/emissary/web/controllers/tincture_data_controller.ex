# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.TinctureDataController do
  @moduledoc """
  The tincture data routes, `Prima.TinctureWire`'s endpoint side:

      POST /_f/v1/invoke  — run a component the tincture declares
      POST /_f/v1/action  — run a system action the tincture declares
      POST /_f/v1/stream  — open a stream the tincture declares

  ## Who is asking

  A frame presents its per-open credential as a bearer and nothing else:
  `Sanctum.Caller.establish({:frame_credential, bearer}, …)` holds it to
  its row and its source's rows at every request, so a suspended,
  revoked, expired or retired-source credential is refused at the next
  request. The context it builds is the frame's person in the frame's
  athanor, bound to the tincture version the frame opened. That version
  is read again (`Compendium.inspect_component/2`) and must still carry
  the release digest the credential names, and the tincture's one active
  owner profile must still be at the grant revision it names (0 while it
  has none): a credential presented for another version or another grant
  is refused. A bearer copied out of its frame carries exactly this
  authority and nothing wider.

  A public tincture's page names the tincture as `public` and presents no
  bearer: it is admitted only for a tincture that is public, under the
  address's public context (`Sanctum.TinctureAccess`), and never under a
  viewer's session — no route here reads a cookie. A request with neither
  is refused as `no_frame`; one with both is refused unread.

  ## What it may reach

  The tincture's declaration is the grant: an invoke names a component
  among its `dependencies.static` (`Compendium.tincture_invokes?/2`), an
  action one of its `actions`, a stream one of its `streams` with a
  subject that declaration takes — and none for a stream bound to its
  holder, whose subject the gate supplies. Anything else is refused before
  dispatch. An admitted invoke runs
  through the gate's `tincture` operation (`invoke_protected` for a frame,
  `invoke_public` for a public page) with the input
  `{"operation": …, "params": …}`; an action through the gate under the
  frame's context; a stream is opened through the gate's one stream entry
  (`Grimoire.open_stream/3`) and delivered by `CyfrWeb.SSE.deliver/4`.

  ## Limits

  Each frame credential holds two limits: an invocation rate, charged on
  every request to any of the three routes (`frame_invocation_max` per
  `frame_invocation_window_ms`), and a count of concurrently open streams
  (`frame_stream_max_concurrent`), released when a stream closes. A
  public page is charged the same rate per address and tincture. Each is
  refused over its bound with a typed refusal.

  Every answer, a refusal included, is the wire's own shape; a refusal
  made here is the request's one recorded decision
  (`CyfrWeb.Plugs.CallIdentity`), and a refusal the gate made is the
  gate's.
  """

  use Emissary.Web, :controller

  @behaviour CyfrWeb.ErrorRenderer

  alias CyfrWeb.Plugs.CallIdentity
  alias Prima.TinctureWire
  alias Sanctum.Context

  @slot_tag :frame_stream

  @doc "Run a component the tincture declares."
  @spec invoke(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def invoke(conn, _params), do: handle(conn, :invoke)

  @doc "Run a system action the tincture declares."
  @spec system_action(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def system_action(conn, _params), do: handle(conn, :action)

  @doc "Open a stream the tincture declares and deliver it."
  @spec stream(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def stream(conn, _params), do: handle(conn, :stream_open)

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
    refusal = %{Grimoire.classify(reason) | stage: :admission}

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
    refusal = Grimoire.classify(reason)

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

  # In order: the body, who is asking, the charge, then the grant. The
  # charge follows the caller, so a frame's undeclared attempts count
  # against it too.
  defp admit(conn, kind) do
    with {:ok, request} <- decode(conn, kind),
         {:ok, caller} <- caller(conn, request) do
      conn = assign(conn, :context, caller.ctx)

      with :ok <- charge(caller),
           :ok <- granted(kind, request, caller) do
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
        frame_caller(conn, bearer)

      {:none, %{} = public} ->
        public_caller(conn, public)

      {:none, nil} ->
        {:error, no_frame()}

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

  # A frame: its credential, the version it opened and the grant it was
  # opened under, each read again now.
  defp frame_caller(conn, bearer) do
    client_ip = Sanctum.ClientIp.resolve(conn)

    with {:ok, ctx} <- establish(bearer, client_ip),
         {:ok, grant} <- frame_grant(ctx) do
      {:ok,
       Map.merge(grant, %{
         ctx: CallIdentity.stamp(conn, ctx),
         route: :protected,
         tincture: ctx.frame.reference,
         bearer: bearer,
         client_ip: client_ip,
         rate_key: {:frame, ctx.frame.id}
       })}
    end
  end

  defp establish(bearer, client_ip) do
    case Sanctum.Caller.establish({:frame_credential, bearer}, client_ip: client_ip) do
      {:ok, %Context{frame: %{}} = ctx} -> {:ok, ctx}
      {:error, reason} -> {:error, credential_refusal(reason)}
    end
  end

  defp frame_grant(%Context{frame: frame} = ctx) do
    %{reference: reference, version_digest: digest, grant_revision: revision} = frame

    with {:ok, manifest} <- version(ctx, reference, digest),
         :ok <- grant_revision(ctx, reference, revision),
         {:ok, declaration} <- declaration(manifest) do
      {:ok, %{manifest: manifest, declaration: declaration}}
    end
  end

  # The version the credential names, when its release digest is still
  # the credential's; any other answer opens nothing.
  defp version(ctx, %{publisher: publisher, name: name, version: version}, digest) do
    reference = Prima.ComponentRef.build("tincture", publisher, name, version)

    case Compendium.inspect_component(ctx, reference) do
      {:ok, %{"release_digest" => ^digest} = row} -> {:ok, decode_manifest(row["manifest"])}
      {:ok, _another_digest} -> {:error, frame_moved()}
      {:error, {:not_found, _reference}} -> {:error, frame_moved()}
      {:error, _unanswered} -> {:error, Prima.Refusal.classify(:unavailable)}
    end
  end

  # The head revision of the tincture's one active owner profile, or 0
  # while it holds none — read as the shell reads it when it mints.
  defp grant_revision(ctx, %{publisher: publisher, name: name}, revision) do
    reference = Prima.ComponentRef.build("tincture", publisher, name)

    with {:ok, entries} <- Sanctum.Consent.profiles(ctx, reference),
         {:ok, current} <- head_revision(ctx, entries) do
      if current == revision, do: :ok, else: {:error, frame_moved()}
    else
      {:error, _unanswered} -> {:error, Prima.Refusal.classify(:unavailable)}
    end
  end

  defp head_revision(ctx, entries) do
    case Prima.Authority.RootSelect.select(entries, :default) do
      {:ok, %{id: profile_id}} ->
        case Sanctum.Consent.head_consent(ctx, profile_id) do
          {:ok, %{revision: revision}} -> {:ok, revision}
          {:error, :not_found} -> {:ok, 0}
          {:error, _unreadable} -> {:error, :unavailable}
        end

      {:error, _no_active_owner} ->
        {:ok, 0}
    end
  end

  # A public tincture's page: the tincture must be public in the athanor
  # its address names, and nothing runs under anything but that
  # address's public context.
  defp public_caller(conn, %{athanor: athanor, publisher: publisher, name: name}) do
    client_ip = Sanctum.ClientIp.resolve(conn)

    with {:ok, public_ctx} <- Sanctum.TinctureAccess.public_context(athanor),
         {:ok, tincture} <- Sanctum.TinctureAccess.get_public(public_ctx, publisher, name),
         {:ok, declaration} <- declaration(tincture.manifest) do
      {:ok,
       %{
         ctx: %{CallIdentity.stamp(conn, public_ctx) | client_ip: client_ip},
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

  defp declaration(manifest) do
    case Compendium.tincture_declaration(manifest) do
      {:ok, declaration} -> {:ok, declaration}
      {:error, _unreadable} -> {:error, undeclared("its declaration does not read")}
    end
  end

  defp decode_manifest(manifest) when is_map(manifest), do: manifest

  defp decode_manifest(manifest) when is_binary(manifest) do
    case Jason.decode(manifest) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_manifest(_manifest), do: %{}

  # The invocation rate, charged per request, per frame credential (per
  # address and tincture for a public page). Both settings serve a stale
  # value, so a store outage answers the last one read.
  defp charge(%{rate_key: key}) do
    {:ok, max} = Arca.PlatformSettings.effective("frame_invocation_max")
    {:ok, window} = Arca.PlatformSettings.effective("frame_invocation_window_ms")

    case Prima.RateLimiter.check({:frame_invocation, key}, max, window) do
      :ok -> :ok
      {:deny, retry_after} -> {:error, Prima.Refusal.classify({:rate_limited, retry_after})}
    end
  end

  # ---------------------------------------------------------------------------
  # The grant: the tincture's declaration
  # ---------------------------------------------------------------------------

  defp granted(:invoke, %{ref: ref}, %{manifest: manifest}) do
    if Compendium.tincture_invokes?(manifest, ref),
      do: :ok,
      else: {:error, undeclared(:component)}
  end

  defp granted(:action, %{operation: operation}, %{declaration: declaration}) do
    if operation in declaration.actions, do: :ok, else: {:error, undeclared(:action)}
  end

  defp granted(:stream_open, %{stream: name, subject: subject}, %{declaration: declaration}) do
    if Enum.any?(declaration.streams, &(&1.name == name and takes?(&1.subject, subject))) and
         not (is_binary(subject) and holder_bound?(name)),
       do: :ok,
       else: {:error, undeclared(:stream)}
  end

  # A declared subject is a literal, `*` for any literal the provider's
  # grammar admits (which the gate checks), or none.
  defp takes?(nil, subject), do: is_nil(subject)
  defp takes?(_declared, nil), do: false

  defp takes?(declared, subject),
    do: declared == Prima.Manifest.Tincture.any_subject() or declared == subject

  # A stream bound to its holder takes no subject from the frame: the
  # gate supplies the holder's own.
  defp holder_bound?(name) do
    case Prima.Provider.fetch_stream(Grimoire.streams(), name) do
      {:ok, stream} -> Prima.Provider.Stream.holder_bound?(stream)
      {:error, :undeclared_stream} -> false
    end
  end

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

  defp dispatch(conn, :stream_open, request, caller), do: open_stream(conn, request, caller)

  # The route fixes the profile the run roots at: a frame's is the
  # tincture's owner profile in its own athanor, a public page's the
  # public profile the address names.
  defp route_args(%{route: :public, address: address}),
    do: %{"action" => "invoke_public", "athanor" => address}

  defp route_args(%{route: :protected}), do: %{"action" => "invoke_protected"}

  # The gate authorizes, casts and records the call under the request's
  # own call id; its refusal is its row.
  defp call(conn, ctx, tool, args) do
    case Grimoire.call_external(tool, ctx, args, call_id: ctx.call_id) do
      {:ok, result} -> json(conn, TinctureWire.result(result))
      {:error, reason} -> refused_by_gate(conn, reason)
    end
  end

  # A frame's stream holds one of its open-stream slots from before the
  # open to the stream's end, whatever ends it. A public page holds none:
  # the gate admits a stream to a signed-in caller alone.
  defp open_stream(conn, %{stream: name, subject: subject}, caller) do
    ctx = caller.ctx

    case claim(ctx) do
      :ok ->
        try do
          case Grimoire.open_stream(ctx, name, subject) do
            {:ok, grant} ->
              conn
              |> CallIdentity.decided()
              |> CyfrWeb.SSE.deliver(ctx, grant,
                name: name,
                revalidate: fn -> revalidate(caller) end
              )

            {:error, refusal} ->
              refused_by_gate(conn, refusal)
          end
        after
          release(ctx)
        end

      {:error, :stream_limit} ->
        refuse(conn, Prima.Refusal.classify(:stream_limit))
    end
  end

  defp claim(%Context{frame: %{}} = ctx),
    do: CyfrWeb.SSE.claim_slot(@slot_tag, ctx, :frame_stream_max_concurrent)

  defp claim(%Context{}), do: :ok

  defp release(%Context{frame: %{}} = ctx), do: CyfrWeb.SSE.release_slot(@slot_tag, ctx)
  defp release(%Context{}), do: :ok

  # The stream's caller established again, as a request would be: the
  # credential, the version and the grant.
  defp revalidate(%{route: :protected, bearer: bearer, client_ip: client_ip}) do
    with {:ok, ctx} <- establish(bearer, client_ip),
         {:ok, _grant} <- frame_grant(ctx) do
      {:ok, ctx}
    end
  end

  # A public page holds no credential to establish again, and the gate
  # admits it no stream to hold one for.
  defp revalidate(%{route: :public}), do: {:error, no_frame()}

  # ---------------------------------------------------------------------------
  # Refusals
  # ---------------------------------------------------------------------------

  defp no_frame do
    %Prima.Refusal{
      class: :unauthenticated,
      reason: :no_frame,
      message: "This request carries no frame credential and names no public tincture"
    }
  end

  defp frame_moved do
    %Prima.Refusal{
      class: :forbidden,
      reason: :frame_moved,
      message: "This tincture changed since its frame opened — open it again"
    }
  end

  defp undeclared(:component),
    do:
      undeclared_refusal(:undeclared_component, "This tincture does not declare that component.")

  defp undeclared(:action),
    do: undeclared_refusal(:undeclared_action, "This tincture does not declare that action.")

  defp undeclared(:stream),
    do: undeclared_refusal(:undeclared_stream, "This tincture does not declare that stream.")

  defp undeclared(why) when is_binary(why),
    do: undeclared_refusal(:undeclared, "This tincture declares nothing it can reach: #{why}.")

  defp undeclared_refusal(reason, message),
    do: %Prima.Refusal{class: :forbidden, reason: reason, message: message}

  # A suspended frame is the shell's to show again; every other refusal of
  # a presented credential is the table's.
  defp credential_refusal(:suspended) do
    %Prima.Refusal{
      class: :forbidden,
      reason: :frame_suspended,
      message: "This frame is suspended — it opens nothing until it is shown again"
    }
  end

  defp credential_refusal(reason), do: Grimoire.classify(reason)
end
