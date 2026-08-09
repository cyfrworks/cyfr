# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.LegalAcceptController do
  @moduledoc """
  Renders the bundled policy text for clickwrap acceptance and posts the
  result to cyfr.run's `POST /v1/legal/accept` endpoint.

  Wired in by:
    * `AuthController.callback` — when the post-OAuth flow detects the
      identity has not accepted the current bundled `policy_version`.
    * `ClaimNamespaceController.submit` — when cyfr.run returns 412
      `POLICY_ACCEPTANCE_REQUIRED` on a claim attempt.

  The IdP `access_token` is read from the same signed
  `_cyfr_pending_probe` cookie that `ClaimNamespaceController` consumes
  (so the user's OAuth roundtrip happens once and feeds both the
  acceptance and the claim).

  YAGNI: rendering is server-rendered HTML inline (no LiveView). The
  page is static enough — markdown bodies + 7 checkboxes — that adding
  a LiveView for the sake of it is overkill at v1.
  """

  use EmissaryWeb, :controller

  require Logger

  alias Compendium.Registry.Client

  @policy_names ~w(terms privacy aup content-policy dmca cookies transparency)

  def show(conn, params) do
    case Client.get_legal_version() do
      {:ok, %{"policy_version" => version, "policies" => policies}} ->
        bodies = fetch_all_bodies(policies)
        provider = Map.get(params, "provider", current_provider(conn))

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, render_page(version, bodies, provider, nil))

      {:error, err} ->
        Logger.error("[LegalAcceptController] get_legal_version failed: #{inspect(err)}")

        conn
        |> put_status(:bad_gateway)
        |> put_resp_content_type("text/html")
        |> send_resp(502, render_error_page("Couldn't load policies from cyfr.run."))
    end
  end

  def submit(conn, %{"policy_version" => version} = params) when is_binary(version) do
    # All 7 acknowledgement checkboxes must be ticked.
    if not all_acknowledged?(params) do
      conn
      |> put_status(:bad_request)
      |> put_resp_content_type("text/html")
      |> send_resp(
        400,
        render_error_page(
          "All policy checkboxes must be ticked before continuing. " <>
            "Please return to the form and confirm each policy."
        )
      )
    else
      with {:ok, conn, access_token} <- pop_pending_probe(conn),
           {:ok, provider} <- current_provider(conn, params),
           {:ok, _body} <-
             Client.accept_policies(provider, access_token, nil, version) do
        # Acceptance recorded server-side. Route to /auth/post-legal-accept
        # so AuthController re-runs probe_and_store with the still-valid
        # access_token (cookie not cleared) and dispatches to /claim-namespace
        # or the dashboard based on the new probe result. This single
        # post-accept landing handles both the probe-gated and claim-gated
        # paths uniformly.
        conn |> redirect(to: "/auth/post-legal-accept")
      else
        {:expired, conn} ->
          conn
          |> put_status(:bad_request)
          |> put_resp_content_type("text/html")
          |> send_resp(
            400,
            render_error_page("Login session expired. Please re-authenticate and try again.")
          )

        {:not_logged_in, conn} ->
          conn |> redirect(to: "/auth/github")

        {:error, %Compendium.OCI.Errors{reason: :policy_version_mismatch} = err} ->
          required = err.detail[:required_version] || err.detail["required_version"]
          # Server bumped between page-load and submit — redirect back to
          # /legal/accept so the user re-reads the new version. Pass
          # required version in query so log shows the divergence.
          query =
            if is_binary(required),
              do: "?required=" <> URI.encode_www_form(required),
              else: ""

          conn |> redirect(to: "/legal/accept" <> query)

        {:error, %Compendium.OCI.Errors{reason: :unauthorized}} ->
          # 403 IDENTITY_BANNED at the accept endpoint. Surface as a flat error.
          conn
          |> put_status(:forbidden)
          |> put_resp_content_type("text/html")
          |> send_resp(
            403,
            render_error_page(
              "This identity is currently restricted from publishing on cyfr.run."
            )
          )

        {:error, :invalid_access_token} ->
          # IdP token expired between OAuth callback and accept submit.
          provider_for_redirect =
            case params["provider"] do
              p when p in ["github", "google"] -> p
              _ -> "github"
            end

          conn
          |> clear_pending_probe()
          |> redirect(to: "/auth/#{provider_for_redirect}")

        {:error, err} ->
          msg =
            case err do
              %Compendium.OCI.Errors{} -> Compendium.OCI.Errors.to_string(err)
              other when is_binary(other) -> other
              other -> inspect(other)
            end

          Logger.error("[LegalAcceptController] accept_policies error: #{msg}")

          conn
          |> put_resp_content_type("text/html")
          |> send_resp(200, render_error_page(msg))
      end
    end
  end

  def submit(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> put_resp_content_type("text/html")
    |> send_resp(400, render_error_page("policy_version is required"))
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp fetch_all_bodies(policies) when is_list(policies) do
    policies
    |> Enum.map(fn %{"name" => name, "title" => title} ->
      case Client.get_legal_page(name) do
        {:ok, %{"content_markdown" => md}} -> {name, title, md}
        _ -> {name, title, "_(failed to load #{name})_"}
      end
    end)
  end

  defp fetch_all_bodies(_), do: []

  defp all_acknowledged?(params) do
    Enum.all?(@policy_names, fn name ->
      ack_field = "ack_" <> String.replace(name, "-", "_")
      params[ack_field] == "on"
    end)
  end

  defp current_provider(conn) do
    case Sanctum.Session.load(get_session(conn, :sanctum_session_token) || "", surface: :console) do
      {:ok, %{provider: p}} when p in ["github", "google"] -> p
      _ -> "github"
    end
  end

  defp current_provider(_conn, %{"provider" => p}) when p in ["github", "google"], do: {:ok, p}
  defp current_provider(conn, _params), do: {:ok, current_provider(conn)}

  defp pop_pending_probe(conn) do
    conn = fetch_cookies(conn, signed: ["_cyfr_pending_probe"])

    case conn.cookies["_cyfr_pending_probe"] do
      token when is_binary(token) and token != "" ->
        {:ok, conn, token}

      _ ->
        # Either no logged-in user or the cookie expired/missing.
        case get_session(conn, :sanctum_session_token) do
          token when is_binary(token) and token != "" -> {:expired, conn}
          _ -> {:not_logged_in, conn}
        end
    end
  end

  defp clear_pending_probe(conn) do
    delete_resp_cookie(conn, "_cyfr_pending_probe")
  end

  # ============================================================================
  # Rendering — minimal inline HTML, same convention as ClaimNamespaceController.
  # ============================================================================

  defp render_page(version, bodies, provider, error) do
    csrf = Plug.CSRFProtection.get_csrf_token()
    safe_version = html_escape(version)
    safe_provider = html_escape(provider || "")
    safe_error = if error, do: html_escape(error), else: ""

    tabs_html =
      bodies
      |> Enum.with_index()
      |> Enum.map(fn {{name, title, _}, i} ->
        active = if i == 0, do: "active", else: ""

        ~s(<button type="button" class="tab #{active}" data-target="tab-#{name}">#{html_escape(title)}</button>)
      end)
      |> Enum.join("\n")

    panes_html =
      bodies
      |> Enum.with_index()
      |> Enum.map(fn {{name, _, md}, i} ->
        active = if i == 0, do: "active", else: ""
        ~s(<div class="pane #{active}" id="tab-#{name}"><pre>#{html_escape(md)}</pre></div>)
      end)
      |> Enum.join("\n")

    checkboxes_html =
      bodies
      |> Enum.map(fn {name, title, _} ->
        field = "ack_" <> String.replace(name, "-", "_")

        ~s(<label class="ack-row"><input type="checkbox" name="#{field}" value="on" required> I have read and agree to the #{html_escape(title)}.</label>)
      end)
      |> Enum.join("\n")

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8"/>
        <title>Accept policies — cyfr.run</title>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <style>
          body { font-family: system-ui, sans-serif; max-width: 56rem; margin: 2rem auto; padding: 0 1rem; }
          h1 { font-size: 1.5rem; }
          p { color: #444; line-height: 1.5; }
          .tabs { display: flex; gap: 0.25rem; flex-wrap: wrap; border-bottom: 1px solid #ccc; margin-top: 1rem; }
          .tab { padding: 0.5rem 1rem; border: 1px solid #ccc; border-bottom: none; background: #f6f8fa; cursor: pointer; font-family: inherit; font-size: 0.9rem; }
          .tab.active { background: white; font-weight: 600; }
          .pane { display: none; max-height: 28rem; overflow: auto; padding: 1rem; border: 1px solid #ccc; border-top: none; }
          .pane.active { display: block; }
          .pane pre { white-space: pre-wrap; font-family: ui-monospace, monospace; font-size: 0.85rem; line-height: 1.45; }
          .ack-row { display: block; margin-top: 0.5rem; font-size: 0.95rem; }
          button[type="submit"] { margin-top: 1.5rem; padding: 0.6rem 1.2rem; font-size: 1rem; cursor: pointer; }
          .error { background: #fee; color: #a00; padding: 0.75rem 1rem; border-radius: 4px; margin-top: 1rem; }
          fieldset { margin-top: 1.5rem; padding: 1rem; border: 1px solid #ddd; border-radius: 4px; }
          legend { padding: 0 0.5rem; font-weight: 600; }
        </style>
      </head>
      <body>
        <h1>Accept policies</h1>
        <p>
          Before publishing on cyfr.run, please review and accept the policies
          below. You're accepting bundle version <code>#{safe_version}</code>.
        </p>
        #{if safe_error != "", do: "<div class=\"error\">" <> safe_error <> "</div>", else: ""}
        <div class="tabs">#{tabs_html}</div>
        <div>#{panes_html}</div>
        <form method="POST" action="/legal/accept/submit">
          <input type="hidden" name="_csrf_token" value="#{csrf}"/>
          <input type="hidden" name="policy_version" value="#{safe_version}"/>
          <input type="hidden" name="provider" value="#{safe_provider}"/>
          <fieldset>
            <legend>Acknowledgements</legend>
            #{checkboxes_html}
          </fieldset>
          <button type="submit">Accept and continue</button>
        </form>
        <script>
          document.querySelectorAll('.tab').forEach(function(btn) {
            btn.addEventListener('click', function() {
              var target = btn.dataset.target;
              document.querySelectorAll('.tab').forEach(function(t) { t.classList.remove('active'); });
              document.querySelectorAll('.pane').forEach(function(p) { p.classList.remove('active'); });
              btn.classList.add('active');
              var pane = document.getElementById(target);
              if (pane) pane.classList.add('active');
            });
          });
        </script>
      </body>
    </html>
    """
  end

  defp render_error_page(msg) do
    safe = html_escape(msg)

    """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"/><title>Error — cyfr.run</title>
    <style>body{font-family:system-ui,sans-serif;max-width:36rem;margin:4rem auto;padding:0 1rem}.error{background:#fee;color:#a00;padding:1rem;border-radius:4px}</style>
    </head><body><h1>Couldn't continue</h1>
    <div class="error">#{safe}</div>
    <p><a href="/legal/accept">Try again</a> · <a href="/auth/github">Sign in again</a></p>
    </body></html>
    """
  end

  defp html_escape(s) when is_binary(s),
    do: s |> Plug.HTML.html_escape_to_iodata() |> IO.iodata_to_binary()

  defp html_escape(_), do: ""
end
