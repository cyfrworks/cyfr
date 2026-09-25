# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.TinctureController do
  @moduledoc """
  Tincture HTTP serving on EmissaryWeb (the platform API surface).

  All clients (Prism shell, CLI, API keys) access tinctures
  through this single controller. Authentication is delegated to
  `Sanctum.TinctureAuth`, which accepts a Phoenix signed token (`?_t=`) or an
  `Authorization: Bearer` credential. Account credentials are never read from
  a query string.

  GET  /t/access-token                                 — mint a short-lived ?_t= token
  GET  /t/:athanor/:publisher/:tincture_name           — serve index.html
  POST /t/:athanor/:publisher/:tincture_name/invoke    — invoke a backend component
  GET  /t/:athanor/:publisher/:tincture_name/*path     — serve static assets
  """

  use EmissaryWeb, :controller

  # A public URL is the public route regardless of authentication, and
  # names the tincture by its address; the private fallback is the
  # protected route, in the caller's own athanor. The action fixes the
  # route.
  defp action_args(:public, athanor), do: %{"action" => "invoke_public", "athanor" => athanor}
  defp action_args(_private, _athanor), do: %{"action" => "invoke_protected"}

  alias Sanctum.TinctureAccess

  # A private tincture's own assets are fetched under a signed `/_s/`
  # prefix: the iframe is sandboxed without `allow-same-origin`, so it
  # carries no cookie and the URL is the only credential it has. That
  # token is `Sanctum.TinctureAuth`'s to mint and to verify — derived from
  # the caller's session or key, held to its rows on every fetch — and this
  # surface only renders the outcome.

  # Base CSP — connect-src is extended dynamically from manifest tincture.connect
  @base_csp_prefix "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " <>
                     "img-src 'self' data:; font-src 'self'; "

  # Tinctures are framed by the Prism shell on this same origin — the one
  # endpoint serves both — so nothing else may frame them. The iframe is
  # sandboxed (`allow-scripts` only, no `allow-same-origin`) with a
  # per-request nonce, and a private tincture additionally requires a
  # credential a third-party framer cannot obtain.
  @base_csp_suffix "object-src 'none'; base-uri 'self'; frame-ancestors 'self'"

  # -------------------------------------------------------------------
  # Access-token mint — a cross-origin client (a CLI, an integration) exchanges its
  # session/Bearer credential (sent as a header, never a URL) for a
  # short-lived, single-purpose `?_t=` token, so a raw credential never
  # travels in a tincture iframe/`<img>` URL. Same-origin Prism mints
  # server-side via `Sanctum.TinctureAuth.issue_access_token/3` directly.
  # -------------------------------------------------------------------

  def access_token(conn, _params) do
    # Credential query params are scrubbed for every response on these routes by
    # `EmissaryWeb.Plugs.ScrubTinctureCredentials` (a `before_send` callback), so
    # `authenticate/1` still sees the raw value here and nothing downstream does.
    result = Sanctum.TinctureAuth.authenticate(conn)

    case result do
      {:ok, %{auth_method: :tincture}} ->
        # A `?_t=` token must not mint its own successor — that would turn a
        # leaked one-hour token into a permanent credential. Minting requires
        # the primary credential; expiry means re-authenticating with it.
        # 403, not 401: the caller IS authenticated, just not with a
        # credential that may mint.
        EmissaryWeb.ApiError.send(conn, 403, :not_primary, nil)

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
            EmissaryWeb.ApiError.send(
              conn,
              400,
              {:invalid_argument, "Name the tincture: publisher and tincture_name"},
              nil
            )
        end

      :unauthenticated ->
        # ApiError attaches the RFC 9110 §15.5.2 challenge on every 401.
        EmissaryWeb.ApiError.send(
          conn,
          401,
          :unauthenticated,
          nil
        )

      {:error, :unavailable} ->
        EmissaryWeb.ApiError.send(conn, 503, :unavailable, nil)

      {:error, reason} ->
        # A presented-but-dead credential says so, at its class's status —
        # the named refusal is what tells a client "re-authenticate" apart
        # from "you never sent anything".
        EmissaryWeb.ApiError.refuse(conn, reason)
    end
  end

  # -------------------------------------------------------------------
  # Index — serve the tincture's entry HTML
  # -------------------------------------------------------------------

  def index(conn, %{
        "athanor" => athanor,
        "publisher" => publisher,
        "tincture_name" => tincture_name
      }) do
    case resolve_tincture(conn, athanor, publisher, tincture_name) do
      {:ok, tincture, :public, ctx} ->
        case Compendium.tincture_entry(tincture) do
          {:ok, entry} ->
            base_href = Prima.TinctureUrl.path(athanor, publisher, tincture_name) <> "/"

            csp = build_csp(tincture.manifest)

            conn
            |> put_resp_header("x-frame-options", "SAMEORIGIN")
            |> CyfrWeb.Ingress.TinctureAssets.serve_index(
              ctx,
              tincture.segments,
              entry,
              base_href,
              csp
            )

          {:error, _no_entry} ->
            EmissaryWeb.ApiError.send(conn, 404, :not_found, nil)
        end

      {:ok, tincture, :private, ctx} ->
        case Compendium.tincture_entry(tincture) do
          {:ok, entry} ->
            case Sanctum.TinctureAuth.issue_asset_token(ctx, publisher, tincture_name) do
              {:ok, token} ->
                base_href =
                  Prima.TinctureUrl.path(athanor, publisher, tincture_name) <> "/_s/#{token}/"

                csp = build_csp(tincture.manifest)

                conn
                |> put_resp_header("x-frame-options", "SAMEORIGIN")
                |> CyfrWeb.Ingress.TinctureAssets.serve_index(
                  ctx,
                  tincture.segments,
                  entry,
                  base_href,
                  csp
                )

              {:error, reason} ->
                mint_refused(conn, reason)
            end

          {:error, _no_entry} ->
            EmissaryWeb.ApiError.send(conn, 404, :not_found, nil)
        end

      {:error, :unavailable} ->
        unavailable(conn)

      {:error, :not_found} ->
        EmissaryWeb.ApiError.send(conn, 404, :not_found, nil)
    end
  end

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

      case Grimoire.call_external(
             "tincture",
             %{ctx | client_ip: Sanctum.ClientIp.resolve(conn)},
             args
           ) do
        {:ok, result} -> json(conn, result)
        {:error, refusal} -> EmissaryWeb.ApiError.refuse(conn, refusal)
      end
    else
      {:error, :unavailable} ->
        unavailable(conn)

      {:error, :not_found} ->
        EmissaryWeb.ApiError.send(conn, 404, :not_found, nil)
    end
  end

  # -------------------------------------------------------------------
  # Assets — static files (JS, CSS, images).
  #
  # Three resolution paths, in order:
  #   1. Path-prefixed signed token (`_s/{token}/...`) — used by the iframe
  #      base_href that the entry route hands out for private tinctures.
  #   2. Public tincture — anyone can fetch.
  #   3. Authenticated session — a picker fetches icons/previews from
  #      <img> tags outside any iframe, so it relies on the same auth that
  #      the entry route uses (MCP session / API key / signed token via
  #      query param, all handled by `Sanctum.TinctureAuth`).
  # -------------------------------------------------------------------

  def asset(conn, %{
        "athanor" => athanor,
        "publisher" => publisher,
        "tincture_name" => tincture_name,
        "path" => segments
      }) do
    # Assets are loaded by the same-origin tincture iframe.
    conn = put_resp_header(conn, "x-frame-options", "SAMEORIGIN")

    case segments do
      ["_s", token | asset_segments] when asset_segments != [] ->
        serve_signed_asset(conn, athanor, publisher, tincture_name, token, asset_segments)

      _ ->
        case resolve_tincture(conn, athanor, publisher, tincture_name) do
          {:ok, tincture, :public, ctx} ->
            conn
            |> page_csp(tincture, segments)
            |> CyfrWeb.Ingress.TinctureAssets.serve_asset(ctx, tincture.segments, segments,
              public: true
            )

          {:ok, tincture, :private, ctx} ->
            conn
            |> page_csp(tincture, segments)
            |> CyfrWeb.Ingress.TinctureAssets.serve_asset(ctx, tincture.segments, segments,
              public: false
            )

          {:error, :unavailable} ->
            unavailable(conn)

          {:error, :not_found} ->
            EmissaryWeb.ApiError.send(conn, 404, :not_found, nil)
        end
    end
  end

  # The token is verified against this request's own athanor, tincture and
  # client address; the bytes are served only through the context it
  # narrows. A store that cannot answer serves nothing.
  defp serve_signed_asset(conn, athanor, publisher, tincture_name, token, segments) do
    outcome =
      with {:ok, public_ctx} <- TinctureAccess.public_context(athanor),
           request_ctx = %{public_ctx | client_ip: Sanctum.ClientIp.resolve(conn)},
           {:ok, ctx} <-
             Sanctum.TinctureAuth.verify_asset_token(token, request_ctx, publisher, tincture_name),
           {:ok, tincture} <- TinctureAccess.lookup(ctx, publisher, tincture_name) do
        {:serve, ctx, tincture}
      end

    case outcome do
      {:serve, ctx, tincture} ->
        conn
        |> page_csp(tincture, segments)
        |> CyfrWeb.Ingress.TinctureAssets.serve_asset(ctx, tincture.segments, segments,
          public: false
        )

      {:error, :expired_credential} ->
        EmissaryWeb.ApiError.send(
          conn,
          401,
          :expired_credential,
          nil
        )

      {:error, :invalid_credential} ->
        EmissaryWeb.ApiError.send(conn, 401, :invalid_credential, nil)

      {:error, :not_member} ->
        EmissaryWeb.ApiError.send(conn, 403, :not_member, nil)

      {:error, reason} when reason in [:not_standing, :ip_not_allowed] ->
        EmissaryWeb.ApiError.send(conn, 403, reason, nil)

      {:error, :unavailable} ->
        unavailable(conn)

      _ ->
        EmissaryWeb.ApiError.send(conn, 404, :not_found, nil)
    end
  end

  # A store that could not say whether the credential stands: retryable,
  # and nothing is served — never read as "not found" or as allowed.
  defp unavailable(conn) do
    conn
    |> put_resp_header("retry-after", "5")
    |> EmissaryWeb.ApiError.send(503, :unavailable, nil)
  end

  # A mint that did not happen is a named state, never a URL: an outage or
  # a member that lost the control plane is retryable, anything else is the
  # caller's credential refusing.
  defp mint_refused(conn, :unavailable), do: unavailable(conn)

  defp mint_refused(conn, :not_owner) do
    conn
    |> put_resp_header("retry-after", "5")
    |> EmissaryWeb.ApiError.send(503, :not_owner, nil)
  end

  # A credential presented and refused is `unauthenticated` — a 401 with
  # its challenge — and one that stands but may not mint is `forbidden`.
  defp mint_refused(conn, reason), do: EmissaryWeb.ApiError.refuse(conn, reason)

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  # Look up the tincture and return the auth context too, so callers can pass
  # `ctx` into Arca-routed serving helpers without re-authenticating. An
  # athanor segment that names no active athanor is a 404 before any lookup,
  # and one the store cannot resolve is a 503.
  defp resolve_tincture(conn, athanor, publisher, tincture_name) do
    with {:ok, public_ctx} <- TinctureAccess.public_context(athanor) do
      case TinctureAccess.get_public(public_ctx, publisher, tincture_name) do
        {:ok, tincture} ->
          {:ok, tincture, :public, public_ctx}

        {:error, :not_found} ->
          # Private fallback: the authenticated caller may only see a private
          # tincture in their OWN athanor, so the URL's athanor must be the
          # resolved context's — otherwise we'd serve one athanor's tincture
          # under another athanor's URL.
          # A store that cannot say who is asking is an outage, never a
          # stranger: it answers `:unavailable`, not an indistinguishable 404.
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

  # An `.html` asset is a PAGE of a multi-page tincture, not a static file:
  # the `:tincture_asset` pipeline's `default-src 'none'; frame-ancestors
  # 'none'` is right for a script or an image and wrong for a document, so a
  # link from the entry to page2.html loaded nothing and could not be framed.
  # `.html` is first in the served-extension roster, so this is the ordinary
  # case, not an exotic one. Everything else keeps the locked-down header.
  defp page_csp(conn, tincture, segments) do
    if segments
       |> List.last()
       |> to_string()
       |> String.downcase()
       |> String.ends_with?(".html") do
      conn
      |> put_resp_header("content-security-policy", build_csp(tincture.manifest))
      |> put_resp_header("x-frame-options", "SAMEORIGIN")
    else
      conn
    end
  end

  defp build_csp(manifest) do
    connect_domains = get_in(manifest || %{}, ["tincture", "connect"]) || []

    extra =
      connect_domains
      |> Enum.filter(&valid_connect_domain?/1)
      |> Enum.map_join(" ", &"https://#{&1}")

    connect_src =
      if extra == "" do
        "connect-src 'self'; "
      else
        "connect-src 'self' #{extra}; "
      end

    @base_csp_prefix <> connect_src <> @base_csp_suffix
  end

  # Validate connect domain entries: allow domain names and wildcard subdomains only.
  # The grammar is the component domain's (`Compendium.valid_tincture_connect_domain?/1`),
  # which the manifest validator holds entries to at publish; this
  # filter stays as defense in depth for manifests that predate the gate.
  defp valid_connect_domain?(domain), do: Compendium.valid_tincture_connect_domain?(domain)
end
