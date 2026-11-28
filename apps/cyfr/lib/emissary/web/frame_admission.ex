# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.FrameAdmission do
  @moduledoc """
  Who a tincture's frame is when it asks: the admission the data routes (`Emissary.Web.TinctureDataController`)
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
  address it asked with.
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

  @doc """
  The frame whose credential `bearer` is, asking from `client_ip`: its
  credential established, then, on a canvas path, that it is the
  credential of the frame the path names, then the version it opened and
  the grant it was opened under, each read again now.

  Options: `path:` is `:shared` (the default) or `{:canvas, frame_id}`;
  `entry:` is the listener the request or its stream came in by, which
  the context carries and the credential's session source is held to;
  `held: true` reads the credential for what it already holds open, held
  to its row rather than to the bearer's own deadline
  (`Sanctum.TinctureAuth.verify_frame_credential/2`), never for a new
  request.
  """
  @spec frame(String.t(), String.t() | nil, keyword()) ::
          {:ok, caller()} | {:error, Prima.Refusal.t()}
  def frame(bearer, client_ip, opts \\ []) when is_binary(bearer) do
    path = Keyword.get(opts, :path, :shared)

    with {:ok, ctx} <- establish(bearer, client_ip, Keyword.take(opts, [:held, :entry])),
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

  # The context carries the frame path's origin from here on, which the
  # runs it starts record.
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

  # The grant the version opens under (`Sanctum.Consent.tincture_grant/2`,
  # read as the shell reads it when it mints), whose revision must be the
  # credential's: a version that reads more than the grant names, or a
  # tincture with no grant, waits for the person and reaches nothing.
  defp grant_revision(ctx, %{publisher: publisher, name: name, version: version}, revision) do
    reference = Prima.ComponentRef.build("tincture", publisher, name, version)

    case Sanctum.Consent.tincture_grant(ctx, reference) do
      {:ok, %{revision: ^revision}} ->
        :ok

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
      {:error, _unreadable} -> {:error, Prima.Refusal.undeclared("its declaration does not read")}
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
