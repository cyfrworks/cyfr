# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.FrameAdmission do
  @moduledoc """
  Who a tincture's frame is when it asks, and what its grant lets it
  carry out: the admission the data routes (`Emissary.Web.TinctureDataController`)
  and a frame's stream connection (`Emissary.Web.FrameSocket`) share.

  ## Who is asking

  A frame presents its per-open credential as a bearer and nothing else:
  `Sanctum.Caller.establish({:frame_credential, bearer}, …)` holds it to
  its row and its source's rows at every request, so a suspended,
  revoked, expired or retired-source credential is refused at the next
  request (`frame/3`). The context it builds is the frame's person in the
  frame's athanor, bound to the tincture version the frame opened. That
  version is read again (`Compendium.inspect_component/2`) and must still
  carry the release digest the credential names, and the grant that
  version opens under must still be the revision it names
  (`Sanctum.Consent.tincture_grant/2`): a credential presented for
  another version or another grant is refused, and one whose version
  reads more than its grant's shape, or whose tincture holds no grant, is
  refused `consent_required`. A bearer copied out of its frame carries
  exactly this authority and nothing wider.

  On a canvas's own data path the bearer is established first and refused
  `forbidden` (`frame_path_mismatch`) unless it is the credential of the
  frame the path names, before its version or grant is read, any charge
  is made or anything is reached.

  The context carries the origin `interactive` (`Prima.Origin`): the
  frame admission path is an interactive surface's, and nothing a frame
  sends names another origin. The origin says how the call was admitted,
  not that a person is present: a hidden frame keeps a standing
  credential only under its tincture's background grant (the shell
  suspends every other hidden frame, `Prism.Frames`), and its calls
  follow that grant's lifecycle rather than any assumption that hidden
  means suspended.

  ## What it may carry out

  A tincture whose page connects to origins beyond the endpoint
  (`tincture.connect`, `Compendium.tincture_connect_origins/1`) may send
  what it reads to each of them, so each is an exit of its frame
  (`Prima.Flow`). A read is admitted only when every source class it may
  carry (`Compendium.tincture_read_classes/1`: an invoke's result, an
  action's answer, a stream's refresh and events) has a flow to every one
  of those origins, spelled as declared, on the ingress edge of the
  tincture's node in the grant its route roots at: the owner profile's
  head at the revision the credential names (read once, with that
  revision) for a frame, the public profile's head for a public page. A
  public page with no grant declares no flow. Otherwise it is refused
  `forbidden` with the classes and the origin (`Prima.Flow.refusal/2`)
  (`flowing/2`). A tincture that connects nowhere, a canvas always, is
  held to nothing here.

  ## The rate

  Each frame credential holds an invocation rate, charged on every
  request (`frame_invocation_max` per `frame_invocation_window_ms`), and
  a public page the same rate per address and tincture (`charge/1`),
  refused over its bound with a typed refusal. Both settings serve a
  stale value, so a store outage answers the last one read.
  """

  alias Sanctum.Context

  @typedoc """
  An admitted caller: its context, its route (`:protected` for a frame,
  `:public` for a public page), its tincture, the manifest and declaration
  of the version it opened, its rate key and, for a frame, the bearer and
  address it asked with and the grant head it is held to.
  """
  @type caller :: %{
          required(:ctx) => Context.t(),
          required(:route) => :protected | :public,
          required(:tincture) => map(),
          required(:manifest) => map(),
          required(:declaration) => term(),
          required(:rate_key) => term(),
          optional(atom()) => term()
        }

  @typedoc "What a read carries: an invoke's result, an action's answer or a stream's events."
  @type read :: :invoke | {:action, String.t()} | {:stream, String.t()}

  @doc """
  The frame whose credential `bearer` is, asking from `client_ip`: its
  credential established, then, on a canvas path, that it is the
  credential of the frame the path names, then the version it opened and
  the grant it was opened under, each read again now.

  Options: `path:` is `:shared` (the default) or `{:canvas, frame_id}`;
  `held: true` reads the credential for what it already holds open, held
  to its row rather than to the bearer's own deadline
  (`Sanctum.TinctureAuth.verify_frame_credential/2`), never for a new
  request.
  """
  @spec frame(String.t(), String.t() | nil, keyword()) ::
          {:ok, caller()} | {:error, Prima.Refusal.t()}
  def frame(bearer, client_ip, opts \\ []) when is_binary(bearer) do
    path = Keyword.get(opts, :path, :shared)

    with {:ok, ctx} <- establish(bearer, client_ip, Keyword.take(opts, [:held])),
         :ok <- on_path(ctx, path),
         {:ok, grant} <- frame_grant(ctx) do
      {:ok,
       Map.merge(grant, %{
         ctx: ctx,
         route: :protected,
         tincture: ctx.frame.reference,
         bearer: bearer,
         client_ip: client_ip,
         rate_key: {:frame, ctx.frame.id}
       })}
    end
  end

  # The context carries the frame path's origin from here on, so the grant
  # the frame is held to (`frame_grant/1`) is read for that origin.
  defp establish(bearer, client_ip, opts) do
    case Sanctum.Caller.establish({:frame_credential, bearer}, [client_ip: client_ip] ++ opts) do
      {:ok, %Context{frame: %{}} = ctx} -> {:ok, interactive(ctx)}
      {:error, reason} -> {:error, credential_refusal(reason)}
    end
  end

  # A canvas path is its own open's: a bearer of any other frame derives
  # nothing on it, its version and grant unread.
  defp on_path(%Context{frame: %{frame_id: frame_id}}, {:canvas, frame_id}), do: :ok
  defp on_path(%Context{}, {:canvas, _another}), do: {:error, frame_path_mismatch()}
  defp on_path(%Context{}, :shared), do: :ok

  @doc """
  The frame admission path's origin on `ctx`. It records how the call was
  admitted, not that a person is watching: a hidden frame's credential
  still stands only under a background grant, and its calls are admitted
  on this path all the same.
  """
  @spec interactive(Context.t()) :: Context.t()
  def interactive(%Context{} = ctx), do: %{ctx | origin: :interactive}

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

  # The grant the version opens under (`Sanctum.Consent.tincture_grant/2`,
  # read as the shell reads it when it mints), whose revision must be the
  # credential's: a version that reads more than the grant names, or a
  # tincture with no grant, waits for the person and reaches nothing. The
  # head is answered beside the check, so what the frame is held to later
  # is this same read.
  defp grant_revision(ctx, %{publisher: publisher, name: name, version: version}, revision) do
    reference = Prima.ComponentRef.build("tincture", publisher, name, version)

    case Sanctum.Consent.tincture_grant(ctx, reference) do
      {:ok, %{revision: ^revision, profile: profile, consent: consent}} ->
        {:ok, {profile, consent}}

      {:ok, _another_revision} ->
        {:error, frame_moved()}

      {:error, :ungranted} ->
        {:error, Prima.Refusal.classify(:consent_required)}

      {:error, :unavailable} ->
        {:error, Prima.Refusal.classify(:unavailable)}

      {:error, {:refused, reason}} ->
        {:error, Sanctum.Refusals.classify(reason)}
    end
  end

  @doc """
  The declaration of `manifest` (`Compendium.tincture_declaration/1`), or
  the refusal of a tincture whose declaration does not read.
  """
  @spec declaration(map()) :: {:ok, term()} | {:error, Prima.Refusal.t()}
  def declaration(manifest) do
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

  @doc "Whether `declaration` is a canvas's: a tincture that declares the `tincture.desktop` block."
  @spec canvas?(term()) :: boolean()
  def canvas?(%Prima.Manifest.Tincture{} = declaration),
    do: Prima.Manifest.Tincture.canvas?(declaration)

  def canvas?(_declaration), do: false

  @doc """
  Charge `caller` one request of its invocation rate: per frame
  credential, per address and tincture for a public page.
  """
  @spec charge(caller()) :: :ok | {:error, Prima.Refusal.t()}
  def charge(%{rate_key: key}) do
    {:ok, max} = Arca.PlatformSettings.effective("frame_invocation_max")
    {:ok, window} = Arca.PlatformSettings.effective("frame_invocation_window_ms")

    case Prima.RateLimiter.check({:frame_invocation, key}, max, window) do
      :ok -> :ok
      {:deny, retry_after} -> {:error, Prima.Refusal.classify({:rate_limited, retry_after})}
    end
  end

  # ---------------------------------------------------------------------------
  # What a read may carry out: the frame's flows
  # ---------------------------------------------------------------------------

  @doc """
  Whether `read` may carry what it reads to every origin `caller`'s page
  connects to. Every class the read may carry needs a flow to every
  origin, decided on the classes before the read is made: what it then
  answers carries no class outside them. A frame that connects nowhere
  reads no grant here. An origin under a declared pattern inherits the
  pattern's flows, by the one function the consent preview shows them
  with (`Prima.Flow.classes_reaching/2`), so the route admits exactly what
  the person was shown.
  """
  @spec flowing(read(), caller()) :: :ok | {:error, Prima.Refusal.t()}
  def flowing(read, %{manifest: manifest} = caller) do
    case Compendium.tincture_connect_origins(manifest) do
      [] ->
        :ok

      origins ->
        classes = Compendium.tincture_read_classes(read)

        with {:ok, flows} <- grant_flows(caller) do
          covered(classes, origins, flows)
        end
    end
  end

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
  # Refusals
  # ---------------------------------------------------------------------------

  @doc "The refusal of a request that carries no frame credential and names no public tincture."
  @spec no_frame() :: Prima.Refusal.t()
  def no_frame do
    %Prima.Refusal{
      class: :unauthenticated,
      reason: :no_frame,
      message: "This request carries no frame credential and names no public tincture"
    }
  end

  @doc "The refusal of a frame that is not a canvas's, on a canvas data path."
  @spec not_a_canvas() :: Prima.Refusal.t()
  def not_a_canvas,
    do:
      undeclared_refusal(
        :not_a_canvas,
        "Only a canvas reads its streams on a canvas data path (not_a_canvas)"
      )

  @doc "The refusal of a canvas's frame on a route every frame shares."
  @spec canvas_path_required() :: Prima.Refusal.t()
  def canvas_path_required,
    do:
      undeclared_refusal(
        :canvas_path_required,
        "A canvas reads its streams on its own data path alone, and invokes or runs " <>
          "nothing (canvas_path_required)"
      )

  # The canvas refusals: each sentence names its code, and no credential or
  # frame id.
  defp frame_path_mismatch,
    do:
      undeclared_refusal(
        :frame_path_mismatch,
        "This frame credential opens only its own frame's data path (frame_path_mismatch)"
      )

  defp frame_moved do
    %Prima.Refusal{
      class: :forbidden,
      reason: :frame_moved,
      message: "This tincture changed since its frame opened — open it again"
    }
  end

  @doc """
  The refusal of what the tincture does not declare: a component, an
  action, a stream, or, as a sentence, why it declares nothing it can
  reach.
  """
  @spec undeclared(:component | :action | :stream | String.t()) :: Prima.Refusal.t()
  def undeclared(:component),
    do:
      undeclared_refusal(:undeclared_component, "This tincture does not declare that component.")

  def undeclared(:action),
    do: undeclared_refusal(:undeclared_action, "This tincture does not declare that action.")

  def undeclared(:stream),
    do: undeclared_refusal(:undeclared_stream, "This tincture does not declare that stream.")

  def undeclared(why) when is_binary(why),
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
