# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.TinctureDataController do
  @moduledoc """
  The tincture data routes, `Prima.TinctureWire`'s endpoint side:

      POST /_f/v1/invoke             — run a component the tincture declares
      POST /_f/v1/action             — run a system action the tincture declares
      POST /_f/v1/stream             — open a stream the tincture declares
      POST /_f/v1/o/:frame_id/stream — open a stream a canvas declares

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

  Either context carries the origin `interactive` (`Prima.Origin`): the
  frame admission path is an interactive surface's, and nothing a frame
  sends names another origin. The origin says how the call was admitted,
  not that a person is present: a hidden frame keeps a standing
  credential only under its tincture's background grant (the shell
  suspends every other hidden frame, `Prism.Frames`), and its calls
  follow that grant's lifecycle rather than any assumption that hidden
  means suspended.

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
  (`Sanctum.Gate.open_stream/3`) and delivered by `CyfrWeb.SSE.deliver/4`.

  ## What it may carry out

  A tincture whose page connects to origins beyond the endpoint
  (`tincture.connect`, `Compendium.tincture_connect_origins/1`) may send
  what it reads to each of them, so each is an exit of its frame
  (`Prima.Flow`). Before anything is read or run, a read is admitted only
  when every source class it may carry (`Compendium.tincture_read_classes/1`:
  an invoke's result, an action's answer, a stream's refresh and events)
  has a flow to every one of those origins, spelled as declared, on the
  ingress edge of the tincture's node in the grant its route roots at: the
  owner profile's head at the revision the credential names (read once,
  with that revision) for a frame, the public profile's head for a public
  page. A tincture with no grant declares no flow. Otherwise it is refused
  `forbidden` with the classes and the origin (`Prima.Flow.refusal/2`). An
  open stream is held to the same check at each revalidation, against the
  grant as it is read then, and ends with that refusal as its last event.
  A tincture that connects nowhere, a canvas always, is held to nothing
  here.

  ## A canvas

  A canvas (a tincture whose placement is `canvas`) reads its streams on
  its own open's data path alone (`Prima.CanvasWire.stream_path/1`), and
  no route there invokes or acts. On that path the bearer is established
  first and refused `forbidden` (`frame_path_mismatch`) unless it is the
  credential of the frame the path names, before its version or grant is
  read, any charge is made or anything is reached; a frame that is not a
  canvas's is refused there `forbidden` (`not_a_canvas`). The shared
  routes refuse a canvas frame's credential `forbidden`
  (`canvas_path_required`), so a canvas invokes no component and runs no
  operation, whatever its declaration names. A canvas path takes no
  public page's request: without a bearer it is `no_frame`.

  A canvas version's validation trial (a frame whose mode is
  `:validation`) is answered on its path from fixtures and admits
  nothing: no gate, no subscription and no open-stream slot. The stream
  it names is answered once and ended: for a feed's results, the envelope
  of the feed the athanor binds under that name (`Opus.feeds/1`), its
  result the fixture of the binding's result shape, and no event for a
  name the athanor does not bind; for another stream, the fixture of the
  stream's shape (`Prima.Canvas.Shape.fixture/1`), and no event for a
  stream that declares none. It is charged as any request is.

  ## Limits

  Each frame credential holds two limits: an invocation rate, charged on
  every request to any of these routes (`frame_invocation_max` per
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

  # The placement a canvas declares, and the stream a canvas reads a
  # feed's results on, by the feed's name as its subject.
  @canvas "canvas"
  @feed_stream "feed.results"

  # A validation answer's feed envelope is the binding's first revision at
  # the epoch: a fixture, never a result the feed produced.
  @fixture_revision 0
  @fixture_at DateTime.from_unix!(0)

  @doc "Run a component the tincture declares."
  @spec invoke(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def invoke(conn, _params), do: handle(conn, :invoke, :shared)

  @doc "Run a system action the tincture declares."
  @spec system_action(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def system_action(conn, _params), do: handle(conn, :action, :shared)

  @doc "Open a stream the tincture declares and deliver it."
  @spec stream(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def stream(conn, _params), do: handle(conn, :stream_open, :shared)

  @doc """
  Open a stream a canvas declares, on the data path of the open the path's
  `frame_id` names, and deliver it; a validation trial's is answered from
  fixtures.
  """
  @spec canvas_stream(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def canvas_stream(conn, %{"frame_id" => frame_id}),
    do: handle(conn, :stream_open, {:canvas, frame_id})

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

  # `path` is the route's: `:shared`, one of the three every frame shares,
  # or `{:canvas, frame_id}`, a canvas open's own data path.
  defp handle(conn, kind, path) do
    case admit(conn, kind, path) do
      {:ok, conn, request, caller} -> dispatch(conn, kind, request, caller, path)
      {:error, conn, refusal} -> refuse(conn, refusal)
    end
  end

  # In order: the body, who is asking (on a canvas path, whether it is the
  # frame the path names, before anything else of it is read), where it
  # may ask, the charge, the grant, then whether what the read may carry
  # may reach every origin the frame connects to. The charge follows the
  # caller, so a frame's undeclared attempts count against it too.
  defp admit(conn, kind, path) do
    with {:ok, request} <- decode(conn, kind),
         {:ok, caller} <- caller(conn, request, path) do
      conn = assign(conn, :context, caller.ctx)

      with :ok <- placed(caller, path),
           :ok <- charge(caller),
           :ok <- granted(kind, request, caller),
           :ok <- flowing(kind, request, caller) do
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

  # A canvas path takes a frame's bearer alone: a request without one is
  # no frame, whatever its body names.
  defp caller(conn, request, path) do
    case {bearer(conn), Map.get(request, :public)} do
      {{:ok, bearer}, nil} ->
        frame_caller(conn, bearer, path)

      {:none, %{} = public} when path == :shared ->
        public_caller(conn, public)

      {:none, _public} ->
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

  # A frame: its credential, the frame its path names when the route names
  # one, the version it opened and the grant it was opened under, each read
  # again now.
  defp frame_caller(conn, bearer, path) do
    client_ip = Sanctum.ClientIp.resolve(conn)

    with {:ok, ctx} <- establish(bearer, client_ip),
         :ok <- on_path(ctx, path),
         {:ok, grant} <- frame_grant(ctx) do
      {:ok,
       Map.merge(grant, %{
         ctx: conn |> CallIdentity.stamp(ctx) |> interactive(),
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

  # A canvas path is its own open's: a bearer of any other frame derives
  # nothing on it, its version and grant unread.
  defp on_path(%Context{frame: %{frame_id: frame_id}}, {:canvas, frame_id}), do: :ok
  defp on_path(%Context{}, {:canvas, _another}), do: {:error, frame_path_mismatch()}
  defp on_path(%Context{}, :shared), do: :ok

  # The frame admission path's origin. It records how the call was
  # admitted, not that a person is watching: a hidden frame's credential
  # still stands only under a background grant, and its calls are
  # admitted on this path all the same.
  defp interactive(%Context{} = ctx), do: %{ctx | origin: :interactive}

  defp frame_grant(%Context{frame: frame} = ctx) do
    %{reference: reference, version_digest: digest, grant_revision: revision} = frame

    with {:ok, manifest} <- version(ctx, reference, digest),
         {:ok, head} <- grant_revision(ctx, reference, revision),
         {:ok, declaration} <- declaration(manifest) do
      {:ok, %{manifest: manifest, declaration: declaration, head: head}}
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

  # The head of the tincture's one active owner profile, whose revision
  # must be the credential's, or none while it holds none, at revision 0 —
  # read as the shell reads it when it mints. The head is answered beside
  # the check, so what the frame is held to later is this same read.
  defp grant_revision(ctx, %{publisher: publisher, name: name}, revision) do
    reference = Prima.ComponentRef.build("tincture", publisher, name)

    with {:ok, entries} <- Sanctum.Consent.profiles(ctx, reference),
         {:ok, head} <- head(ctx, Prima.Authority.RootSelect.select(entries, :default)) do
      if head_revision(head) == revision, do: {:ok, head}, else: {:error, frame_moved()}
    else
      {:error, _unanswered} -> {:error, Prima.Refusal.classify(:unavailable)}
    end
  end

  # A selected profile's head, `{profile, consent}`, or `:none` for no
  # profile or no head.
  defp head(ctx, {:ok, %{id: profile_id} = profile}) do
    case Sanctum.Consent.head_consent(ctx, profile_id) do
      {:ok, consent} -> {:ok, {profile, consent}}
      {:error, :not_found} -> {:ok, :none}
      {:error, _unreadable} -> {:error, :unavailable}
    end
  end

  defp head(_ctx, {:error, _no_profile}), do: {:ok, :none}

  defp head_revision({_profile, %{revision: revision}}), do: revision
  defp head_revision(:none), do: 0

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
         ctx: %{interactive(CallIdentity.stamp(conn, public_ctx)) | client_ip: client_ip},
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

  # Where a frame may ask: a canvas on its own data path alone, and on that
  # path only a canvas. A public page's request reaches no canvas path.
  defp placed(%{route: :protected, declaration: declaration}, :shared) do
    if canvas?(declaration), do: {:error, canvas_path_required()}, else: :ok
  end

  defp placed(%{route: :public}, :shared), do: :ok

  defp placed(%{declaration: declaration}, {:canvas, _frame_id}) do
    if canvas?(declaration), do: :ok, else: {:error, not_a_canvas()}
  end

  defp canvas?(%{frame: %{placement: @canvas}}), do: true
  defp canvas?(_declaration), do: false

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
    case Prima.Provider.fetch_stream(Sanctum.Catalog.streams(), name) do
      {:ok, stream} -> Prima.Provider.Stream.holder_bound?(stream)
      {:error, :undeclared_stream} -> false
    end
  end

  # ---------------------------------------------------------------------------
  # What a read may carry out: the frame's flows
  # ---------------------------------------------------------------------------

  # The page sends what the frame reads wherever it connects, so every
  # class the read may carry needs a flow to every origin, decided on the
  # classes the read may carry before it is made: what it then answers
  # carries no class outside them. A frame that connects nowhere reads
  # no grant here. An origin under a declared pattern inherits the
  # pattern's flows, by the one function the consent preview shows them
  # with (`Prima.Flow.classes_reaching/2`), so the route admits exactly
  # what the person was shown.
  defp flowing(kind, request, %{manifest: manifest} = caller) do
    case Compendium.tincture_connect_origins(manifest) do
      [] ->
        :ok

      origins ->
        classes = Compendium.tincture_read_classes(read(kind, request))

        with {:ok, flows} <- grant_flows(caller) do
          covered(classes, origins, flows)
        end
    end
  end

  defp read(:invoke, _request), do: :invoke
  defp read(:action, %{operation: operation}), do: {:action, operation}
  defp read(:stream_open, %{stream: name}), do: {:stream, name}

  defp covered(classes, origins, flows) do
    Enum.reduce_while(origins, :ok, fn origin, :ok ->
      case classes -- Prima.Flow.classes_reaching(flows, origin) do
        [] -> {:cont, :ok}
        uncovered -> {:halt, {:error, flow_refusal(uncovered, origin)}}
      end
    end)
  end

  defp flow_refusal(classes, origin) do
    classes
    |> Enum.map(&Prima.Source.new/1)
    |> Prima.Flow.refusal({:domain, origin})
    |> Prima.Refusal.classify()
  end

  # The flows of the grant the route roots at: a frame's is the owner
  # head its credential's revision was checked against, a public page's
  # the public profile's head, read now under the address's context.
  defp grant_flows(%{route: :protected, ctx: ctx, head: head, tincture: tincture}),
    do: flows(ctx, head, tincture_node(tincture))

  defp grant_flows(%{route: :public, ctx: ctx, tincture: tincture}) do
    node = tincture_node(tincture)

    with {:ok, entries} <- Sanctum.Consent.profiles(ctx, node),
         selected =
           Prima.Authority.RootSelect.select_for_route(entries, :public, ctx.authenticated),
         {:ok, head} <- head(ctx, selected) do
      flows(ctx, head, node)
    else
      {:error, _unanswered} -> {:error, Prima.Refusal.classify(:unavailable)}
    end
  end

  defp tincture_node(%{publisher: publisher, name: name}),
    do: Prima.ComponentRef.build("tincture", publisher, name)

  # The ingress edge of the tincture's own node, in the head's blob as the
  # loader reads it (`Sanctum.Consent.Loader.admitted_blob/3`). No grant
  # declares no flow. A head that cannot be trusted, one without its own
  # node's ingress among them, is the loader's one reading of that damage
  # (`Sanctum.Consent.Loader.damage_refusal/3`), and any other refusal of
  # the loader stands as it gave it.
  defp flows(_ctx, :none, _node), do: {:ok, []}

  defp flows(ctx, {profile, consent}, node) do
    with {:ok, blob} <- Sanctum.Consent.Loader.admitted_blob(ctx, profile, consent),
         {:ok, edge} <- ingress(blob, node) do
      {:ok, Prima.Authority.Blob.Edge.flows(edge)}
    else
      {:error, reason} ->
        reason =
          if Sanctum.Consent.Loader.damage?(reason),
            do: Sanctum.Consent.Loader.damage_refusal(reason, profile.id, node),
            else: reason

        {:error, Sanctum.Refusals.classify(reason)}
    end
  end

  defp ingress(blob, node) do
    case Prima.Authority.Blob.ingress(blob, node) do
      {:ok, edge} -> {:ok, edge}
      {:error, :missing_ingress} -> {:error, {:missing_ingress, node}}
    end
  end

  # ---------------------------------------------------------------------------
  # Dispatch
  # ---------------------------------------------------------------------------

  # A canvas's validation trial is answered on its own path and admits
  # nothing; every other request is dispatched as its kind asks.
  defp dispatch(
         conn,
         :stream_open,
         request,
         %{ctx: %Context{frame: %{mode: :validation}}} = caller,
         {:canvas, _frame_id}
       ),
       do: validation_answer(conn, request, caller)

  defp dispatch(conn, kind, request, caller, _path), do: dispatch(conn, kind, request, caller)

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
    case Sanctum.Gate.call_external(tool, ctx, args, call_id: ctx.call_id) do
      {:ok, result} -> json(conn, TinctureWire.result(result))
      {:error, reason} -> refused_by_gate(conn, reason)
    end
  end

  # A frame's stream holds one of its open-stream slots from before the
  # open to the stream's end, whatever ends it. A public page holds none:
  # the gate admits a stream to a signed-in caller alone.
  defp open_stream(conn, %{stream: name, subject: subject} = request, caller) do
    ctx = caller.ctx

    case claim(ctx) do
      :ok ->
        try do
          case Sanctum.Gate.open_stream(ctx, name, subject) do
            {:ok, grant} ->
              conn
              |> CallIdentity.decided()
              |> CyfrWeb.SSE.deliver(ctx, grant,
                name: name,
                revalidate: fn -> revalidate(caller, request) end
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

  # The stream a validation trial names, answered once from its fixtures
  # and ended: a `text/event-stream` of at most one event, under no grant,
  # with no subscription and no slot. A feed's bindings the store cannot
  # read are refused before the stream opens.
  defp validation_answer(conn, %{stream: name, subject: subject}, caller) do
    case fixtures(caller.ctx, name, subject) do
      {:ok, events} -> conn |> CyfrWeb.SSE.open() |> write_events(name, events)
      {:error, refusal} -> refuse(conn, refusal)
    end
  end

  # A feed's results: the envelope of the feed the athanor binds under the
  # subject's name, its result the fixture of the binding's result shape;
  # none for a name the athanor does not bind.
  defp fixtures(ctx, @feed_stream, subject) do
    case Opus.feeds(ctx) do
      {:ok, feeds} ->
        {:ok,
         for %{binding_id: id, binding: %{name: ^subject} = binding} <- feeds do
           result = Prima.Canvas.Shape.fixture(binding.result_shape)
           Prima.Feed.envelope(id, binding, @fixture_revision, @fixture_at, result)
         end}

      {:error, _unanswered} ->
        {:error, Prima.Refusal.classify(:unavailable)}
    end
  end

  # Another stream: the fixture of its shape, and none for a stream that
  # declares no shape.
  defp fixtures(_ctx, name, _subject) do
    case Prima.Provider.fetch_stream(Sanctum.Catalog.streams(), name) do
      {:ok, %Prima.Provider.Stream{shape: %{} = shape}} ->
        {:ok, [Prima.Canvas.Shape.fixture(shape)]}

      _shapeless ->
        {:ok, []}
    end
  end

  # No event carries an id: a fixture has no place in its topic's
  # sequence.
  defp write_events(conn, name, events) do
    Enum.reduce_while(events, conn, fn data, conn ->
      case chunk(conn, TinctureWire.stream_event(nil, name, data)) do
        {:ok, conn} -> {:cont, conn}
        {:error, _closed} -> {:halt, conn}
      end
    end)
  end

  # The stream's caller established again, as a request would be: the
  # credential, the version, the grant, and what its events may carry to
  # the origins the frame connects to, against the grant as it is read now.
  defp revalidate(%{route: :protected, bearer: bearer, client_ip: client_ip} = caller, request) do
    with {:ok, ctx} <- establish(bearer, client_ip),
         {:ok, grant} <- frame_grant(ctx),
         :ok <- flowing(:stream_open, request, Map.merge(caller, grant)) do
      {:ok, ctx}
    end
  end

  # A public page holds no credential to establish again, and the gate
  # admits it no stream to hold one for.
  defp revalidate(%{route: :public}, _request), do: {:error, no_frame()}

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

  # The canvas refusals: each sentence names its code, and no credential or
  # frame id.
  defp frame_path_mismatch,
    do:
      undeclared_refusal(
        :frame_path_mismatch,
        "This frame credential opens only its own frame's data path (frame_path_mismatch)"
      )

  defp not_a_canvas,
    do:
      undeclared_refusal(
        :not_a_canvas,
        "Only a canvas reads its streams on a canvas data path (not_a_canvas)"
      )

  defp canvas_path_required,
    do:
      undeclared_refusal(
        :canvas_path_required,
        "A canvas reads its streams on its own data path alone, and invokes or runs " <>
          "nothing (canvas_path_required)"
      )

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

  defp credential_refusal(reason), do: Sanctum.Refusals.classify(reason)
end
