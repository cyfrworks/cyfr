# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.TinctureController do
  @moduledoc """
  Tincture HTTP serving on EmissaryWeb (the platform API surface).

  All clients (Prism shell, Porta desktop, CLI, API keys) access tinctures
  through this single controller. Authentication is delegated to
  `Sanctum.TinctureAuth` which supports Phoenix signed tokens, MCP sessions,
  and API keys via query parameters.

  GET  /t/access-token                        — mint a short-lived ?_t= token
  GET  /t/:publisher/:tincture_name           — serve index.html
  POST /t/:publisher/:tincture_name/invoke    — invoke a backend component
  GET  /t/:publisher/:tincture_name/*path     — serve static assets
  """

  use EmissaryWeb, :controller

  @compile {:no_warn_undefined, [Opus.Executor, Opus.Chain]}

  # A public URL is the public route regardless of authentication; the
  # private fallback is the protected route.
  defp route_for(:public), do: :public
  defp route_for(_), do: :protected

  require Logger

  alias Emissary.MCP.RequestLog
  alias Sanctum.TinctureAccess

  @token_salt "tincture_access"
  @token_max_age 86_400

  # Base CSP — connect-src is extended dynamically from manifest tincture.connect
  @base_csp_prefix "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " <>
                     "img-src 'self' data:; font-src 'self'; "

  # `frame-ancestors *` is deliberate, not an oversight: the first-party shells
  # that embed tinctures are themselves cross-origin to this endpoint — Prism runs
  # on :4001 while tinctures are served from EmissaryWeb on :4000, and in direct
  # mode the Porta PWA runs on :8080 (only same-origin once a reverse proxy fronts
  # both in TLS mode). A fixed `'self'`/host allowlist would break those embeds
  # across deployment modes. Framing is not an escalation vector here: the iframe
  # is sandboxed (`allow-scripts` only, no `allow-same-origin`) with a per-request
  # nonce, and private tinctures additionally require a credential a third-party
  # framer cannot obtain, so a hostile embed cannot read state or act as the user.
  @base_csp_suffix "object-src 'none'; base-uri 'self'; frame-ancestors *"

  # Rate limiting now delegated to Sanctum.Policy + Opus.RateLimiter

  # -------------------------------------------------------------------
  # Access-token mint — a cross-origin client (Porta) exchanges its
  # session/Bearer credential (sent as a header, never a URL) for a
  # short-lived, single-purpose `?_t=` token, so a raw credential never
  # travels in a tincture iframe/`<img>` URL. Same-origin Prism mints
  # server-side via `Sanctum.TinctureAuth.issue_access_token/1` directly.
  # -------------------------------------------------------------------

  def access_token(conn, _params) do
    result = Sanctum.TinctureAuth.authenticate(conn)
    # Scrub credential query params AFTER auth so no log sink / error report
    # observes a raw credential for the remainder of the pipeline.
    conn = Sanctum.TinctureAuth.scrub_conn(conn)

    case result do
      {:ok, ctx} ->
        conn
        |> put_status(200)
        |> json(%{token: Sanctum.TinctureAuth.issue_access_token(ctx), expires_in: 3600})

      :unauthenticated ->
        conn |> put_status(401) |> json(%{error: "unauthenticated"})
    end
  end

  # -------------------------------------------------------------------
  # Index — serve the tincture's entry HTML
  # -------------------------------------------------------------------

  def index(conn, %{
        "org" => org,
        "project" => project,
        "publisher" => publisher,
        "tincture_name" => tincture_name
      }) do
    case resolve_tincture(conn, org, project, publisher, tincture_name) do
      {:ok, tincture, :public, ctx} ->
        case Cyfr.TinctureHelpers.resolve_entry(tincture) do
          {:ok, entry} ->
            base_href =
              Cyfr.TinctureHelpers.tincture_path(org, project, publisher, tincture_name) <> "/"

            csp = build_csp(tincture.manifest)

            conn
            |> delete_resp_header("x-frame-options")
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
                {org, project, publisher, tincture_name}
              )

            base_href =
              Cyfr.TinctureHelpers.tincture_path(org, project, publisher, tincture_name) <>
                "/_s/#{token}/"

            csp = build_csp(tincture.manifest)

            conn
            |> delete_resp_header("x-frame-options")
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
          "org" => org,
          "project" => project,
          "publisher" => publisher,
          "tincture_name" => tincture_name
        } = params
      ) do
    reference = params["reference"]
    input = params["input"] || %{}

    with {:ok, tincture, visibility, auth_ctx} <-
           resolve_tincture(conn, org, project, publisher, tincture_name),
         tincture_ref = "tincture:#{publisher}.#{tincture_name}",
         {:ok, policy, _meta} <- Sanctum.Policy.get_effective(auth_ctx, tincture_ref),
         :ok <- check_policy_rate_limit(conn, policy, auth_ctx, tincture_ref) do
      manifest = tincture.manifest || %{}

      cond do
        !is_binary(reference) or reference == "" ->
          conn |> put_status(400) |> json(%{error: "missing reference"})

        !is_map(input) ->
          conn |> put_status(400) |> json(%{error: "input must be an object"})

        not TinctureAccess.can_invoke?(manifest, reference) ->
          conn |> put_status(403) |> json(%{error: "component not in dependencies"})

        true ->
          tincture_ctx_base = Sanctum.build_tincture_context(auth_ctx, tincture)
          request_id = Emissary.UUID7.request_id()
          tincture_ctx = %{tincture_ctx_base | request_id: request_id}

          run_logged_invoke(
            conn,
            tincture_ctx,
            request_id,
            publisher,
            tincture_name,
            reference,
            input,
            tincture_ref: tincture_ref,
            route: route_for(visibility)
          )
      end
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Not Found"})

      {:error, :rate_limited, retry_after} ->
        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_status(429)
        |> json(%{error: "Rate limit exceeded"})

      {:error, reason} ->
        Logger.warning("[TinctureInvoke] request failed: #{inspect(reason)}")
        conn |> put_status(400) |> json(%{error: "Bad request"})
    end
  end

  # -------------------------------------------------------------------
  # Assets — static files (JS, CSS, images).
  #
  # Three resolution paths, in order:
  #   1. Path-prefixed signed token (`_s/{token}/...`) — used by the iframe
  #      base_href that the entry route hands out for private tinctures.
  #   2. Public tincture — anyone can fetch.
  #   3. Authenticated session — Porta picker fetches icons/previews from
  #      <img> tags outside any iframe, so it relies on the same auth that
  #      the entry route uses (MCP session / API key / signed token via
  #      query param, all handled by `Sanctum.TinctureAuth`).
  # -------------------------------------------------------------------

  def asset(conn, %{
        "org" => org,
        "project" => project,
        "publisher" => publisher,
        "tincture_name" => tincture_name,
        "path" => segments
      }) do
    # Delete x-frame-options for assets loaded by tincture iframes
    conn = delete_resp_header(conn, "x-frame-options")

    case segments do
      ["_s", token | asset_segments] when asset_segments != [] ->
        serve_signed_asset(conn, org, project, publisher, tincture_name, token, asset_segments)

      _ ->
        case resolve_tincture(conn, org, project, publisher, tincture_name) do
          {:ok, tincture, :public, ctx} ->
            Cyfr.TinctureHelpers.serve_asset(conn, ctx, tincture.segments, segments,
              public: true,
              cors: true
            )

          {:ok, tincture, :private, ctx} ->
            Cyfr.TinctureHelpers.serve_asset(conn, ctx, tincture.segments, segments,
              public: false,
              cors: true
            )

          {:error, :not_found} ->
            send_resp(conn, 404, "Not Found")
        end
    end
  end

  defp serve_signed_asset(conn, org, project, publisher, tincture_name, token, segments) do
    case Phoenix.Token.verify(EmissaryWeb.Endpoint, @token_salt, token, max_age: @token_max_age) do
      {:ok, {^org, ^project, ^publisher, ^tincture_name}} ->
        public_ctx = Cyfr.TinctureHelpers.build_public_context(org, project)

        case TinctureAccess.lookup(public_ctx, publisher, tincture_name) do
          {:ok, tincture} ->
            Cyfr.TinctureHelpers.serve_asset(conn, public_ctx, tincture.segments, segments,
              public: false,
              cors: true
            )

          {:error, _} ->
            send_resp(conn, 404, "Not Found")
        end

      _ ->
        send_resp(conn, 404, "Not Found")
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  # Look up the tincture and return the auth context too, so callers can pass
  # `ctx` into Arca-routed serving helpers without re-authenticating.
  defp resolve_tincture(conn, org, project, publisher, tincture_name) do
    public_ctx = Cyfr.TinctureHelpers.build_public_context(org, project)

    case TinctureAccess.get_public(public_ctx, publisher, tincture_name) do
      {:ok, tincture} ->
        {:ok, tincture, :public, public_ctx}

      {:error, :not_found} ->
        # Private fallback: the authenticated caller may only see a private
        # tincture in their OWN workspace, so the URL's workspace must match
        # the resolved context — otherwise we'd serve one workspace's tincture
        # under another workspace's URL.
        case Sanctum.TinctureAuth.authenticate(conn) do
          {:ok, %Sanctum.Context{} = ctx} ->
            if workspace_matches?(ctx, org, project) do
              case TinctureAccess.get_private(ctx, publisher, tincture_name) do
                {:ok, tincture} -> {:ok, tincture, :private, ctx}
                {:error, _} -> {:error, :not_found}
              end
            else
              {:error, :not_found}
            end

          :unauthenticated ->
            {:error, :not_found}
        end
    end
  end

  # The URL's workspace must equal the authenticated context's workspace
  # (normalized) — private tinctures are scoped to the caller's current
  # workspace.
  defp workspace_matches?(%Sanctum.Context{} = ctx, org, project) do
    Arca.QueryHelpers.normalize_org_id(ctx.org_id) ==
      Arca.QueryHelpers.normalize_org_id(org) and
      Arca.QueryHelpers.normalize_project_id(ctx.project_id) ==
        Arca.QueryHelpers.normalize_project_id(project)
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

  # Build a scoped execution context for tincture invoke.
  #
  # Preserves the actual user_id from the auth context (for audit trails).
  # For public/unauthenticated access, uses the tincture identity as user_id.
  # Permissions are limited to [:execute] regardless of the original context.
  # Tincture execution context is built by `Sanctum.build_tincture_context/2`
  # (single source of truth, shared with the Prism shell).

  # Run the invoke with full request logging (Arca.McpLog) and telemetry.
  # Logging is best-effort via RequestLog.safe_log_*; failures never block
  # or fail the underlying invocation.
  defp run_logged_invoke(
         conn,
         ctx,
         request_id,
         publisher,
         tincture_name,
         reference,
         input,
         opts
       ) do
    tincture_ref = opts[:tincture_ref] || "tincture:#{publisher}.#{tincture_name}"

    log_input = %{
      publisher: publisher,
      tincture_name: tincture_name,
      reference: reference,
      input: input
    }

    telemetry_meta = %{
      request_id: request_id,
      tincture_ref: tincture_ref,
      reference: reference,
      org_id: ctx.org_id,
      project_id: ctx.project_id,
      user_id: ctx.user_id
    }

    RequestLog.safe_log_started(ctx, request_id, %{
      tool: "tincture",
      action: "invoke",
      method: "POST /t/invoke",
      input: log_input
    })

    start_time = System.monotonic_time()

    :telemetry.execute(
      [:cyfr, :emissary, :tincture, :invoke, :start],
      %{system_time: System.system_time()},
      telemetry_meta
    )

    # Cutover: the tincture's profile owns the authority, selected by the
    # route — a public URL selects the public profile whatever cookies the
    # caller holds. A tincture without a profile keeps the legacy path.
    run_result =
      if Opus.Chain.ingress_enabled?(:tincture) do
        case Opus.Chain.run_root_edge(ctx, tincture_ref, reference, input,
               route: opts[:route],
               client_ip: Sanctum.ClientIp.resolve(conn)
             ) do
          {:error, no_profile}
          when no_profile in [:no_profile, :no_public_profile] ->
            Opus.Executor.run(ctx, reference, input)

          other ->
            other
        end
      else
        Opus.Executor.run(ctx, reference, input)
      end

    case run_result do
      {:ok, result} ->
        duration_ms = duration_ms(start_time)

        RequestLog.safe_log_completed(ctx, request_id, %{
          output: result.output,
          duration_ms: duration_ms,
          routed_to: "opus"
        })

        :telemetry.execute(
          [:cyfr, :emissary, :tincture, :invoke, :stop],
          %{duration_ms: duration_ms},
          Map.put(telemetry_meta, :status, :ok)
        )

        json(conn, %{
          status: result.status,
          output: result.output,
          execution_id: result.metadata.execution_id,
          duration_ms: result.metadata.duration_ms
        })

      {:error, reason} ->
        duration_ms = duration_ms(start_time)
        Logger.warning("[TinctureInvoke] error: #{inspect(reason)}")

        RequestLog.safe_log_failed(ctx, request_id, %{
          error: inspect(reason),
          duration_ms: duration_ms,
          routed_to: "opus"
        })

        :telemetry.execute(
          [:cyfr, :emissary, :tincture, :invoke, :stop],
          %{duration_ms: duration_ms},
          telemetry_meta |> Map.put(:status, :error) |> Map.put(:error, inspect(reason))
        )

        conn |> put_status(500) |> json(%{error: "Execution failed"})
    end
  end

  defp duration_ms(start_time) do
    System.monotonic_time()
    |> Kernel.-(start_time)
    |> System.convert_time_unit(:native, :millisecond)
  end

  # The policy rate limiter buckets on {org, project, component_ref} only —
  # every public caller of one tincture shares a single bucket, and the
  # transport-level per-IP plug beneath this is what bounds an individual
  # client. The IP rewrite below does NOT create per-client buckets; it
  # exists so rate-limit denial audit rows attribute the denied request to
  # a client IP instead of an anonymous context.
  defp check_policy_rate_limit(conn, policy, ctx, tincture_ref) do
    rate_ctx =
      if ctx.authenticated do
        ctx
      else
        # Same client-IP resolution (and XFF trust boundary) as the API-key
        # allowlist, so audit attribution and the allowlist agree on client
        # identity behind a proxy.
        ip = Sanctum.ClientIp.resolve(conn)
        %{ctx | user_id: "ip:#{ip}"}
      end

    case Sanctum.Policy.check_rate_limit(policy, rate_ctx, tincture_ref) do
      {:ok, _remaining} ->
        :ok

      {:error, :rate_limited, retry_ms} ->
        {:error, :rate_limited, max(div(retry_ms, 1000), 1)}

      {:error, reason} ->
        # Fail CLOSED, matching Policy.check_rate_limit's contract and the
        # Executor path — a degraded limiter must not become an open gate.
        Logger.error(
          "[TinctureInvoke] rate limiter unavailable for #{tincture_ref}: #{inspect(reason)}, denying request"
        )

        {:error, :rate_limited, 1}
    end
  end
end
