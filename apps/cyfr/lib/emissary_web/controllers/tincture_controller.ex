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

  # A public URL is the public route regardless of authentication; the
  # private fallback is the protected route.
  defp route_for(:public), do: :public
  defp route_for(_), do: :protected

  alias Sanctum.TinctureAccess

  # The signed prefix a private tincture's own assets are fetched under: the
  # iframe is sandboxed without `allow-same-origin`, so it carries no cookie
  # and the URL is the only credential it has. It therefore names the person
  # it was minted for and lives as long as the `?_t=` token, not a day: a
  # URL that reached anyone else is a URL that opens nothing.
  @token_salt "tincture_asset_v2"
  @token_max_age 3_600

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
  # server-side via `Sanctum.TinctureAuth.issue_access_token/1` directly.
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
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> put_status(401)
        |> EmissaryWeb.ApiError.send(403, :token_cannot_renew_itself, "A minted tincture token cannot mint another")

      {:ok, ctx} ->
        conn
        |> put_status(200)
        |> json(%{
          token: Sanctum.TinctureAuth.issue_access_token(ctx),
          expires_in: Sanctum.TinctureAuth.access_token_max_age()
        })

      :unauthenticated ->
        # RFC 9110 §15.5.2 makes a challenge mandatory on a 401.
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> put_status(401)
        |> EmissaryWeb.ApiError.send(401, :unauthenticated, "Authentication required")
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
        case Cyfr.TinctureHelpers.resolve_entry(tincture) do
          {:ok, entry} ->
            base_href =
              Cyfr.TinctureHelpers.tincture_path(athanor, publisher, tincture_name) <> "/"

            csp = build_csp(tincture.manifest)

            conn
            |> put_resp_header("x-frame-options", "SAMEORIGIN")
            |> Cyfr.TinctureHelpers.serve_index(ctx, tincture.segments, entry, base_href, csp)

          :error ->
            send_resp(conn, 404, "Not Found")
        end

      {:ok, tincture, :private, ctx} ->
        case Cyfr.TinctureHelpers.resolve_entry(tincture) do
          {:ok, entry} ->
            token =
              Phoenix.Token.sign(
                EmissaryWeb.Endpoint,
                @token_salt,
                {athanor, publisher, tincture_name, ctx.user_id}
              )

            base_href =
              Cyfr.TinctureHelpers.tincture_path(athanor, publisher, tincture_name) <>
                "/_s/#{token}/"

            csp = build_csp(tincture.manifest)

            conn
            |> put_resp_header("x-frame-options", "SAMEORIGIN")
            |> Cyfr.TinctureHelpers.serve_index(ctx, tincture.segments, entry, base_href, csp)

          :error ->
            send_resp(conn, 404, "Not Found")
        end

      {:error, :not_found} ->
        send_resp(conn, 404, "Not Found")
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
    reference = params["reference"]
    input = params["input"] || %{}

    with {:ok, tincture, visibility, auth_ctx} <-
           resolve_tincture(conn, athanor, publisher, tincture_name) do
      tincture_ref = "tincture:#{publisher}.#{tincture_name}"

      _ = tincture_ref

      # One implementation for both invoke surfaces (the console shell is
      # the other) — validation, context, logging, telemetry and the
      # readiness gate live in Emissary.Tincture.Invoke; this surface only
      # renders its outcomes.
      case Emissary.Tincture.Invoke.run(auth_ctx, tincture, reference, input,
             route: route_for(visibility),
             method: "POST /t/invoke",
             client_ip: Sanctum.ClientIp.resolve(conn)
           ) do
        {:ok, result} ->
          json(conn, result)

        {:error, :invalid_params, msg} ->
          EmissaryWeb.ApiError.send(conn, 400, :invalid_params, msg)

        {:error, :consent_required, msg} ->
          EmissaryWeb.ApiError.send(conn, 403, :consent_required, msg)

        {:error, :service_unavailable, msg} ->
          EmissaryWeb.ApiError.send(conn, 503, :service_unavailable, msg)

        {:error, :execution_failed, msg} ->
          EmissaryWeb.ApiError.send(conn, 500, :execution_failed, msg)
      end
    else
      {:error, :not_found} ->
        EmissaryWeb.ApiError.send(conn, 404, :not_found, "Not found")
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
            Cyfr.TinctureHelpers.serve_asset(conn, ctx, tincture.segments, segments, public: true)

          {:ok, tincture, :private, ctx} ->
            Cyfr.TinctureHelpers.serve_asset(conn, ctx, tincture.segments, segments,
              public: false
            )

          {:error, :not_found} ->
            send_resp(conn, 404, "Not Found")
        end
    end
  end

  defp serve_signed_asset(conn, athanor, publisher, tincture_name, token, segments) do
    with {:ok, {^athanor, ^publisher, ^tincture_name, user_id}} <-
           Phoenix.Token.verify(EmissaryWeb.Endpoint, @token_salt, token, max_age: @token_max_age),
         {:ok, public_ctx} <- Cyfr.TinctureHelpers.build_public_context(athanor),
         :ok <- asset_reader_standing(user_id, public_ctx.athanor_id),
         {:ok, tincture} <- TinctureAccess.lookup(public_ctx, publisher, tincture_name) do
      Cyfr.TinctureHelpers.serve_asset(conn, public_ctx, tincture.segments, segments,
        public: false
      )
    else
      _ ->
        send_resp(conn, 404, "Not Found")
    end
  end

  # The token names a person; the athanor says whether they are still one of
  # its own. The bytes are then served through the public context (path
  # resolution only) exactly as before.
  defp asset_reader_standing(user_id, athanor_id) when is_binary(user_id) do
    if Sanctum.Tenancy.Members.member?(user_id, athanor_id) or platform_admin?(user_id),
      do: :ok,
      else: {:error, :not_member}
  end

  defp asset_reader_standing(_user_id, _athanor_id), do: {:error, :no_user}

  defp platform_admin?(user_id) do
    case Sanctum.Tenancy.Members.list_by_user(user_id) do
      {:ok, rows} -> Enum.any?(rows, &(&1.scope == "platform"))
      {:error, _} -> false
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  # Look up the tincture and return the auth context too, so callers can pass
  # `ctx` into Arca-routed serving helpers without re-authenticating. An
  # athanor segment that names no active athanor is a 404 before any lookup.
  defp resolve_tincture(conn, athanor, publisher, tincture_name) do
    with {:ok, public_ctx} <- Cyfr.TinctureHelpers.build_public_context(athanor) do
      case TinctureAccess.get_public(public_ctx, publisher, tincture_name) do
        {:ok, tincture} ->
          {:ok, tincture, :public, public_ctx}

        {:error, :not_found} ->
          # Private fallback: the authenticated caller may only see a private
          # tincture in their OWN athanor, so the URL's athanor must be the
          # resolved context's — otherwise we'd serve one athanor's tincture
          # under another athanor's URL.
          case Sanctum.TinctureAuth.authenticate(conn) do
            {:ok, %Sanctum.Context{athanor_id: id} = ctx} when id == public_ctx.athanor_id ->
              case TinctureAccess.get_private(ctx, publisher, tincture_name) do
                {:ok, tincture} -> {:ok, tincture, :private, ctx}
                {:error, _} -> {:error, :not_found}
              end

            _ ->
              {:error, :not_found}
          end
      end
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
  # Reject bare wildcards, IP addresses, paths, ports, and schemes.
  defp valid_connect_domain?(domain) when is_binary(domain) do
    # Strip leading *. for validation
    base = String.replace_prefix(domain, "*.", "")

    cond do
      domain == "*" -> false
      String.contains?(domain, "/") -> false
      String.contains?(domain, ":") -> false
      String.contains?(domain, " ") -> false
      # Must look like a domain name (letters+digits+hyphens, ends with TLD of 2+ chars)
      not Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/, base) -> false
      true -> true
    end
  end

  defp valid_connect_domain?(_), do: false

end
