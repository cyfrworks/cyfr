# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Ingress.TinctureController do
  @moduledoc """
  Tincture HTTP serving on the host's ingress (the platform API surface).

  A public tincture is served at its address, to anyone; a private
  tincture version's files only under an asset credential in their path
  (`Prima.TinctureUrl`), which `Sanctum.TinctureAuth` mints for a person
  and verifies on every request. No other credential opens a private
  tincture's files: the credential names the person, the version and its
  window, so the path is the whole of the authority a frame carries.

  GET  /t/:athanor/:publisher/:tincture_name           — a public tincture's entry page
  GET  /t/:athanor/:publisher/:tincture_name/*path     — a public tincture's files
  GET  /_s/:credential/:publisher/:name/:version/*file — a private tincture version's files
  GET  /t/access-token                                 — mint a short-lived ?_t= token
  POST /t/:athanor/:publisher/:tincture_name/invoke    — invoke a backend component

  The bytes and their headers are `CyfrWeb.Ingress.TinctureAssets`'.
  """

  use CyfrWeb.Ingress, :controller

  alias CyfrWeb.Ingress.TinctureAssets
  alias Sanctum.TinctureAccess

  # A public tincture's files may be cached for this long; its address,
  # which follows its latest version, is revalidated.
  @public_max_age 3600

  # A public URL is the public route regardless of authentication, and
  # names the tincture by its address; the private fallback is the
  # protected route, in the caller's own athanor. The action fixes the
  # route.
  defp action_args(:public, athanor), do: %{"action" => "invoke_public", "athanor" => athanor}
  defp action_args(_private, _athanor), do: %{"action" => "invoke_protected"}

  # -------------------------------------------------------------------
  # Access-token mint — a cross-origin client (a CLI, an integration) exchanges its
  # session/Bearer credential (sent as a header, never a URL) for a
  # short-lived, single-purpose `?_t=` token, so a raw credential never
  # travels in a tincture iframe/`<img>` URL. Same-origin Prism mints
  # server-side via `Sanctum.TinctureAuth.issue_access_token/3` directly.
  # -------------------------------------------------------------------

  def access_token(conn, _params) do
    # Credential query params are scrubbed for every response on these routes by
    # `CyfrWeb.Plugs.ScrubTinctureCredentials` (a `before_send` callback), so
    # `authenticate/1` still sees the raw value here and nothing downstream does.
    result = Sanctum.TinctureAuth.authenticate(conn)

    case result do
      {:ok, %{auth_method: :tincture}} ->
        # A `?_t=` token must not mint its own successor — that would turn a
        # leaked one-hour token into a permanent credential. Minting requires
        # the primary credential; expiry means re-authenticating with it.
        # 403, not 401: the caller IS authenticated, just not with a
        # credential that may mint.
        CyfrWeb.ApiError.send(conn, 403, :not_primary, nil)

      {:ok, ctx} ->
        # The token opens one tincture, so the mint asks which. Without that
        # the endpoint could only issue an athanor-wide credential, which is
        # the thing the scoping exists to prevent.
        case {conn.params["publisher"], conn.params["tincture_name"]} do
          {publisher, name} when is_binary(publisher) and is_binary(name) ->
            # `expires_in` is the signed deadline's remainder: a source that
            # expires sooner than the hour shortens the token with it.
            with {:ok, token} <- Sanctum.TinctureAuth.issue_access_token(ctx, publisher, name),
                 {:ok, expires_in} <- Sanctum.TinctureAuth.expires_in(token) do
              conn
              |> put_status(200)
              |> json(%{token: token, expires_in: expires_in})
            else
              {:error, reason} -> mint_refused(conn, reason)
            end

          _ ->
            CyfrWeb.ApiError.send(
              conn,
              400,
              {:invalid_argument, "Name the tincture: publisher and tincture_name"},
              nil
            )
        end

      :unauthenticated ->
        # ApiError attaches the RFC 9110 §15.5.2 challenge on every 401.
        CyfrWeb.ApiError.send(
          conn,
          401,
          :unauthenticated,
          nil
        )

      {:error, :unavailable} ->
        CyfrWeb.ApiError.send(conn, 503, :unavailable, nil)

      {:error, reason} ->
        # A presented-but-dead credential says so, at its class's status —
        # the named refusal is what tells a client "re-authenticate" apart
        # from "you never sent anything".
        CyfrWeb.ApiError.refuse(conn, reason)
    end
  end

  # -------------------------------------------------------------------
  # A public tincture: its entry page at its address, and its files
  # -------------------------------------------------------------------

  def index(conn, %{
        "athanor" => athanor,
        "publisher" => publisher,
        "tincture_name" => tincture_name
      }) do
    with {:ok, tincture, ctx} <- resolve_public(athanor, publisher, tincture_name),
         {:ok, entry} <- Compendium.tincture_entry(tincture) do
      TinctureAssets.serve(conn, ctx, tincture, String.split(entry, "/"),
        cache: :revalidate,
        base: Prima.TinctureUrl.path(athanor, publisher, tincture_name) <> "/"
      )
    else
      {:error, :unavailable} -> unavailable(conn)
      {:error, _not_found_or_no_entry} -> CyfrWeb.ApiError.send(conn, 404, :not_found, nil)
    end
  end

  def asset(conn, %{
        "athanor" => athanor,
        "publisher" => publisher,
        "tincture_name" => tincture_name,
        "path" => segments
      }) do
    case resolve_public(athanor, publisher, tincture_name) do
      {:ok, tincture, ctx} ->
        TinctureAssets.serve(conn, ctx, tincture, segments,
          cache: {:public, @public_max_age},
          base: Prima.TinctureUrl.path(athanor, publisher, tincture_name) <> "/"
        )

      {:error, :unavailable} ->
        unavailable(conn)

      {:error, :not_found} ->
        CyfrWeb.ApiError.send(conn, 404, :not_found, nil)
    end
  end

  # -------------------------------------------------------------------
  # A private tincture version's files, under an asset credential
  # -------------------------------------------------------------------

  # The credential is verified on every request, against the rows it
  # names as they are now: a retired source, a person or athanor that
  # changed standing, or a window that ended refuses the next fetch. The
  # version is read in the credential's athanor and served only when its
  # release digest (`Compendium.ReleaseDigest`: its bytes bound to its
  # manifest) is the one the credential names; the bytes are read through the
  # context the credential narrows, and cached for no longer than it has
  # left.
  def served(conn, %{"path" => segments}) do
    with {:ok, %{credential: credential, path: [publisher, name, version | file]}}
         when file != [] <-
           Prima.TinctureUrl.parse_asset_path([Prima.TinctureUrl.asset_prefix() | segments]),
         client_ip = Sanctum.ClientIp.resolve(conn),
         {:ok, authority} <-
           Sanctum.TinctureAuth.verify_asset_credential(credential, client_ip: client_ip),
         ctx = asset_context(authority, client_ip),
         {:ok, tincture} <- version(ctx, publisher, name, version, authority.version_digest) do
      TinctureAssets.serve(conn, ctx, tincture, file,
        cache: {:private, authority.remaining_s},
        base: Prima.TinctureUrl.asset_path(credential, [publisher, name, version]) <> "/"
      )
    else
      {:error, reason}
      when reason in [:invalid_credential, :expired_credential] ->
        CyfrWeb.ApiError.send(conn, 401, reason, nil)

      {:error, reason} when reason in [:not_member, :not_standing, :ip_not_allowed] ->
        CyfrWeb.ApiError.send(conn, 403, reason, nil)

      {:error, :unavailable} ->
        unavailable(conn)

      _not_found ->
        CyfrWeb.ApiError.send(conn, 404, :not_found, nil)
    end
  end

  # What the credential opens, as a context: reads in the person's
  # athanor, bound to the credential's source and deadline. It is not an
  # authenticated caller — only `Sanctum.Caller.establish/2` builds one —
  # and carries no permission: it names whose bytes are read, and nothing
  # runs under it.
  defp asset_context(authority, client_ip) do
    Sanctum.Context.build(
      user_id: authority.user_id,
      athanor_id: authority.athanor_id,
      scope: :athanor,
      authenticated: false,
      credential_binding: authority.credential_binding,
      credential_deadline: authority.expires_at,
      client_ip: client_ip
    )
  end

  # The version the path names, in the credential's athanor, when its
  # release digest is the credential's; any other version, absent or not, is not
  # found.
  defp version(ctx, publisher, name, version, digest) do
    with :ok <- Prima.ComponentRef.validate_ref_parts(publisher, name),
         :ok <- Prima.ComponentRef.validate_version(version) do
      reference =
        Prima.ComponentRef.to_string(%Prima.ComponentRef{
          type: "tincture",
          namespace: publisher,
          name: name,
          version: version
        })

      case Compendium.inspect_component(ctx, reference) do
        {:ok, %{"release_digest" => ^digest} = row} ->
          {:ok,
           %{
             segments: Prima.ComponentPath.version_dir("tincture", publisher, name, version),
             manifest: decode_manifest(row["manifest"])
           }}

        {:ok, _another_version} ->
          {:error, :not_found}

        {:error, {:not_found, _reference}} ->
          {:error, :not_found}

        # The reference was held to its grammar above, so any other refusal
        # is the store's: it could not say, and nothing is served.
        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    else
      _malformed -> {:error, :not_found}
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

  # -------------------------------------------------------------------
  # Invoke — execute a backend component on behalf of the tincture
  # -------------------------------------------------------------------

  def invoke(
        conn,
        %{
          "athanor" => athanor,
          "publisher" => publisher,
          "tincture_name" => tincture_name
        } = params
      ) do
    with {:ok, _tincture, visibility, ctx} <-
           resolve_tincture(conn, athanor, publisher, tincture_name) do
      # The same declared operation the console shell and `/mcp` call,
      # through the one gate: it authorizes, casts and logs the call, and
      # `Crucible.invoke_tincture/3` reads the tincture again. The rate
      # limit and the origin rules stay this route's own.
      args =
        %{
          "publisher" => publisher,
          "tincture_name" => tincture_name,
          "reference" => params["reference"],
          "input" => params["input"] || %{}
        }
        |> Map.merge(action_args(visibility, athanor))
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      # The context carries the request's identity (the pipeline's,
      # `CyfrWeb.Plugs.CallIdentity`), so the gate's decision is this
      # request's; a refusal it answers is its row, and the renderer
      # appends no second one.
      ctx = CyfrWeb.Plugs.CallIdentity.stamp(conn, ctx)

      case Grimoire.call_external(
             "tincture",
             %{ctx | client_ip: Sanctum.ClientIp.resolve(conn)},
             args,
             call_id: ctx.call_id
           ) do
        {:ok, result} ->
          json(conn, result)

        {:error, refusal} ->
          conn
          |> CyfrWeb.Plugs.CallIdentity.decided()
          |> CyfrWeb.ApiError.refuse(refusal)
      end
    else
      {:error, :unavailable} ->
        unavailable(conn)

      {:error, :not_found} ->
        CyfrWeb.ApiError.send(conn, 404, :not_found, nil)
    end
  end

  # A store that could not say whether the credential stands: retryable,
  # and nothing is served — never read as "not found" or as allowed.
  defp unavailable(conn) do
    conn
    |> put_resp_header("retry-after", "5")
    |> CyfrWeb.ApiError.send(503, :unavailable, nil)
  end

  # A mint that did not happen is a named state, never a URL: an outage or
  # a member that lost the control plane is retryable, anything else is the
  # caller's credential refusing.
  defp mint_refused(conn, :unavailable), do: unavailable(conn)

  defp mint_refused(conn, :not_owner) do
    conn
    |> put_resp_header("retry-after", "5")
    |> CyfrWeb.ApiError.send(503, :not_owner, nil)
  end

  # A credential presented and refused is `unauthenticated` — a 401 with
  # its challenge — and one that stands but may not mint is `forbidden`.
  defp mint_refused(conn, reason), do: CyfrWeb.ApiError.refuse(conn, reason)

  # -------------------------------------------------------------------
  # Resolution
  # -------------------------------------------------------------------

  # A public tincture in the athanor the address names, with the public
  # context its bytes are read under. An athanor segment that names no
  # active athanor is not found, and one the store cannot resolve is
  # unavailable.
  defp resolve_public(athanor, publisher, tincture_name) do
    with {:ok, public_ctx} <- TinctureAccess.public_context(athanor),
         {:ok, tincture} <- TinctureAccess.get_public(public_ctx, publisher, tincture_name) do
      {:ok, tincture, public_ctx}
    end
  end

  # The invoke route's reading: the public tincture, or else a private one
  # in the authenticated caller's own athanor — the URL's athanor must be
  # the resolved context's, or one athanor's tincture would run under
  # another's URL. A store that cannot say who is asking is an outage,
  # never a stranger.
  defp resolve_tincture(conn, athanor, publisher, tincture_name) do
    with {:ok, public_ctx} <- TinctureAccess.public_context(athanor) do
      case TinctureAccess.get_public(public_ctx, publisher, tincture_name) do
        {:ok, tincture} ->
          {:ok, tincture, :public, public_ctx}

        {:error, :not_found} ->
          case Sanctum.TinctureAuth.authenticate(conn) do
            {:ok, %Sanctum.Context{athanor_id: id} = ctx} when id == public_ctx.athanor_id ->
              case TinctureAccess.get_private(ctx, publisher, tincture_name) do
                {:ok, tincture} -> {:ok, tincture, :private, ctx}
                {:error, _} -> {:error, :not_found}
              end

            {:error, :unavailable} ->
              {:error, :unavailable}

            _ ->
              {:error, :not_found}
          end
      end
    end
  end
end
