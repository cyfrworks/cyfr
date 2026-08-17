# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LegalAcceptController do
  @moduledoc """
  Renders the bundled policy text for clickwrap acceptance and posts the
  result to cyfr.run's `POST /v1/legal/accept` endpoint.

  Wired in by:
    * `AuthController.callback` — when the post-OAuth flow detects the
      identity has not accepted the current bundled `policy_version`.
    * `ClaimNamespaceController.submit` — when cyfr.run returns 412
      `POLICY_ACCEPTANCE_REQUIRED` on a claim attempt.

  The IdP `access_token` is read from the same encrypted
  `_cyfr_pending_probe` cookie that `ClaimNamespaceController` consumes
  (so the user's OAuth roundtrip happens once and feeds both the
  acceptance and the claim).

  Rendered as plain pages in the Prism root layout (`PrismWeb.LegalAcceptHTML`):
  the submit consumes the encrypted `_cyfr_pending_probe` cookie, which is
  Plug-side state a LiveView could neither read nor clear.
  """

  use PrismWeb, :controller

  require Logger

  alias Compendium.Registry.Client

  @policy_names ~w(terms privacy aup content-policy dmca cookies transparency)

  def show(conn, params) do
    case Client.get_legal_version() do
      {:ok, %{"policy_version" => version, "policies" => policies}} ->
        bodies = fetch_all_bodies(policies)
        provider = Map.get(params, "provider", current_provider(conn))

        page(conn, 200, version, bodies, provider, nil)

      {:error, err} ->
        Logger.error("[LegalAcceptController] get_legal_version failed: #{inspect(err)}")
        error_page(conn, 502, "Couldn't load policies from cyfr.run.")
    end
  end

  def submit(conn, %{"policy_version" => version} = params) when is_binary(version) do
    # All 7 acknowledgement checkboxes must be ticked.
    if not all_acknowledged?(params) do
      error_page(
        conn,
        400,
        "All policy checkboxes must be ticked before continuing. " <>
          "Please return to the form and confirm each policy."
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
          error_page(conn, 400, "Login session expired. Please re-authenticate and try again.")

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
          error_page(conn, 403, "This identity is currently restricted from publishing on cyfr.run.")

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
          error_page(conn, 200, msg)
      end
    end
  end

  def submit(conn, _params), do: error_page(conn, 400, "policy_version is required")

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

  # `AuthController.maybe_stash_pending_probe/3` writes this cookie with
  # `encrypt: true`; fetching it `signed:` fails verification and reads as nil.
  defp pop_pending_probe(conn) do
    conn = fetch_cookies(conn, encrypted: ["_cyfr_pending_probe"])

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
  # Rendering — the two pages, in the Prism root layout
  # ============================================================================

  defp page(conn, status, version, bodies, provider, error) do
    conn
    |> put_status(status)
    |> render(:show,
      version: version,
      bodies: bodies,
      provider: provider || "",
      error: error,
      csrf_token: Plug.CSRFProtection.get_csrf_token()
    )
  end

  defp error_page(conn, status, message) do
    conn
    |> put_status(status)
    |> render(:error, message: message)
  end
end
