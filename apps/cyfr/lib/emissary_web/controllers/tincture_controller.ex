defmodule EmissaryWeb.TinctureController do
  @moduledoc """
  Tincture HTTP serving on EmissaryWeb (the platform API surface).

  All clients (Prism shell, Porta desktop, CLI, API keys) access tinctures
  through this single controller. Authentication is delegated to
  `Sanctum.TinctureAuth` which supports Phoenix signed tokens, MCP sessions,
  and API keys via query parameters.

  GET  /t/:publisher/:tincture_name           — serve index.html
  POST /t/:publisher/:tincture_name/invoke    — invoke a backend component
  GET  /t/:publisher/:tincture_name/*path     — serve static assets
  """

  use EmissaryWeb, :controller

  @compile {:no_warn_undefined, [Opus.Executor]}

  require Logger

  alias Emissary.MCP.RequestLog
  alias Sanctum.TinctureAccess

  @token_salt "tincture_access"
  @token_max_age 86_400

  # Base CSP — connect-src is extended dynamically from manifest tincture.connect
  @base_csp_prefix "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " <>
                      "img-src 'self' data:; font-src 'self'; "

  @base_csp_suffix "object-src 'none'; base-uri 'self'; frame-ancestors *"

  # Rate limiting now delegated to Sanctum.Policy + Opus.RateLimiter

  # -------------------------------------------------------------------
  # Index — serve the tincture's entry HTML
  # -------------------------------------------------------------------

  def index(conn, %{"publisher" => publisher, "tincture_name" => tincture_name}) do
    case resolve_tincture(conn, publisher, tincture_name) do
      {:ok, tincture, :public} ->
        case Cyfr.TinctureHelpers.resolve_entry(tincture) do
          {:ok, file_path} ->
            base_href = "/t/#{publisher}/#{tincture_name}/"
            csp = build_csp(tincture.manifest)

            conn
            |> delete_resp_header("x-frame-options")
            |> Cyfr.TinctureHelpers.serve_index(file_path, base_href, csp)

          :error ->
            send_resp(conn, 404, "Not Found")
        end

      {:ok, tincture, :private} ->
        case Cyfr.TinctureHelpers.resolve_entry(tincture) do
          {:ok, file_path} ->
            token = Phoenix.Token.sign(EmissaryWeb.Endpoint, @token_salt, {publisher, tincture_name})
            base_href = "/t/#{publisher}/#{tincture_name}/_s/#{token}/"
            csp = build_csp(tincture.manifest)

            conn
            |> delete_resp_header("x-frame-options")
            |> Cyfr.TinctureHelpers.serve_index(file_path, base_href, csp)

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

  def invoke(conn, %{
        "publisher" => publisher,
        "tincture_name" => tincture_name
      } = params) do
    reference = params["reference"]
    input = params["input"] || %{}

    with {:ok, tincture, _visibility, auth_ctx} <- resolve_tincture_with_ctx(conn, publisher, tincture_name),
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
          tincture_ctx_base = build_tincture_context(auth_ctx, tincture)
          request_id = Emissary.UUID7.request_id()
          tincture_ctx = %{tincture_ctx_base | request_id: request_id}
          run_logged_invoke(conn, tincture_ctx, request_id, publisher, tincture_name, reference, input)
      end
    else
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Not Found"})
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
        "publisher" => publisher,
        "tincture_name" => tincture_name,
        "path" => segments
      }) do
    # Delete x-frame-options for assets loaded by tincture iframes
    conn = delete_resp_header(conn, "x-frame-options")

    case segments do
      ["_s", token | asset_segments] when asset_segments != [] ->
        serve_signed_asset(conn, publisher, tincture_name, token, asset_segments)

      _ ->
        case resolve_tincture(conn, publisher, tincture_name) do
          {:ok, tincture, :public} ->
            Cyfr.TinctureHelpers.serve_asset(conn, tincture.dir, segments,
              public: true,
              cors: true
            )

          {:ok, tincture, :private} ->
            Cyfr.TinctureHelpers.serve_asset(conn, tincture.dir, segments,
              public: false,
              cors: true
            )

          {:error, :not_found} ->
            send_resp(conn, 404, "Not Found")
        end
    end
  end

  defp serve_signed_asset(conn, publisher, tincture_name, token, segments) do
    case Phoenix.Token.verify(EmissaryWeb.Endpoint, @token_salt, token, max_age: @token_max_age) do
      {:ok, {^publisher, ^tincture_name}} ->
        public_ctx = Cyfr.TinctureHelpers.build_public_context()

        case TinctureAccess.lookup(public_ctx, publisher, tincture_name) do
          {:ok, tincture} ->
            Cyfr.TinctureHelpers.serve_asset(conn, tincture.dir, segments, public: false, cors: true)

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

  defp resolve_tincture(conn, publisher, tincture_name) do
    public_ctx = Cyfr.TinctureHelpers.build_public_context()

    case TinctureAccess.get_public(public_ctx, publisher, tincture_name) do
      {:ok, tincture} ->
        {:ok, tincture, :public}

      {:error, :not_found} ->
        case Sanctum.TinctureAuth.authenticate(conn) do
          {:ok, %Sanctum.Context{} = ctx} ->
            case TinctureAccess.get_private(ctx, publisher, tincture_name) do
              {:ok, tincture} -> {:ok, tincture, :private}
              {:error, _} -> {:error, :not_found}
            end

          :unauthenticated ->
            {:error, :not_found}
        end
    end
  end

  # Like resolve_tincture but also returns the auth context for reuse
  # (avoids re-authenticating in build_tincture_context).
  defp resolve_tincture_with_ctx(conn, publisher, tincture_name) do
    public_ctx = Cyfr.TinctureHelpers.build_public_context()

    case TinctureAccess.get_public(public_ctx, publisher, tincture_name) do
      {:ok, tincture} ->
        {:ok, tincture, :public, public_ctx}

      {:error, :not_found} ->
        case Sanctum.TinctureAuth.authenticate(conn) do
          {:ok, %Sanctum.Context{} = ctx} ->
            case TinctureAccess.get_private(ctx, publisher, tincture_name) do
              {:ok, tincture} -> {:ok, tincture, :private, ctx}
              {:error, _} -> {:error, :not_found}
            end

          :unauthenticated ->
            {:error, :not_found}
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

  # Build a scoped execution context for tincture invoke.
  #
  # Preserves the actual user_id from the auth context (for audit trails).
  # For public/unauthenticated access, uses the tincture identity as user_id.
  # Permissions are limited to [:execute] regardless of the original context.
  defp build_tincture_context(%Sanctum.Context{} = auth_ctx, tincture) do
    # Use real user_id for authenticated requests (audit trail),
    # fall back to tincture identity for public access.
    # Guard against nil — execution_records table has NOT NULL on user_id.
    tincture_id = "tincture:#{tincture.publisher}.#{tincture.name}"

    user_id =
      if auth_ctx.authenticated and is_binary(auth_ctx.user_id) do
        auth_ctx.user_id
      else
        tincture_id
      end

    Sanctum.Context.build(
      user_id: user_id,
      permissions: [:execute],
      org_id: auth_ctx.org_id || "",
      project_id: auth_ctx.project_id || "default",
      auth_method: :local,
      authenticated: true
    )
  end

  # Run the invoke with full request logging (Arca.McpLog) and telemetry.
  # Logging is best-effort via RequestLog.safe_log_*; failures never block
  # or fail the underlying invocation.
  defp run_logged_invoke(conn, ctx, request_id, publisher, tincture_name, reference, input) do
    tincture_ref = "tincture:#{publisher}.#{tincture_name}"

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

    case Opus.Executor.run(ctx, reference, input) do
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

  # For unauthenticated (public) requests, key rate limits by IP so each
  # client gets its own bucket. Without this, all public users would share
  # a single rate limit bucket (the context has no user_id).
  defp check_policy_rate_limit(conn, policy, ctx, tincture_ref) do
    rate_ctx =
      if ctx.authenticated do
        ctx
      else
        ip = conn.remote_ip |> :inet.ntoa() |> to_string()
        %{ctx | user_id: "ip:#{ip}"}
      end

    case Sanctum.Policy.check_rate_limit(policy, rate_ctx, tincture_ref) do
      {:ok, _remaining} ->
        :ok

      {:error, :rate_limited, retry_ms} ->
        {:error, :rate_limited, max(div(retry_ms, 1000), 1)}

      {:error, reason} ->
        Logger.warning("[TinctureInvoke] rate limiter error for #{tincture_ref}: #{inspect(reason)}, allowing request")
        :ok
    end
  end
end
