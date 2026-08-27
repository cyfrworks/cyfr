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

  The IdP `access_token` is read from the same pending-probe cookie
  (`PrismWeb.PendingProbe`) that `ClaimNamespaceController` consumes
  (so the user's OAuth roundtrip happens once and feeds both the
  acceptance and the claim).

  Rendered as plain pages in the Prism root layout (`PrismWeb.LegalAcceptHTML`):
  the submit consumes the encrypted `_cyfr_pending_probe` cookie, which is
  Plug-side state a LiveView could neither read nor clear.
  """

  use PrismWeb, :controller

  require Logger

  alias Compendium.Registry.Client
  alias PrismWeb.PendingProbe

  def show(conn, params) do
    case Client.get_legal_version() do
      {:ok, %{"policy_version" => version, "policies" => policies}} ->
        bodies = fetch_all_bodies(version, policies)
        provider = Map.get(params, "provider", current_provider(conn))

        page(conn, 200, version, bodies, provider, nil)

      {:error, err} ->
        Logger.error("[LegalAcceptController] get_legal_version failed: #{inspect(err)}")
        error_page(conn, 502, "Couldn't load policies from cyfr.run.")
    end
  end

  def submit(conn, %{"policy_version" => version} = params) when is_binary(version) do
    # Every acknowledgement checkbox the form rendered must be ticked. The
    # roster rides in the form itself — the server's policy list, not a
    # local copy that goes stale when cyfr.run adds or retires a policy.
    # (Trimming it client-side cheats nobody: cyfr.run enforces acceptance
    # by version on its side.)
    if not all_acknowledged?(params) do
      error_page(
        conn,
        400,
        "All policy checkboxes must be ticked before continuing. " <>
          "Please return to the form and confirm each policy."
      )
    else
      with {:ok, conn, access_token} <- PendingProbe.pop(conn),
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
          conn |> redirect(to: "/login")

        {:error, %Compendium.OCI.Errors{reason: :policy_version_mismatch} = err} ->
          required = Compendium.OCI.Errors.required_version(err)
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
          error_page(
            conn,
            403,
            "This identity is currently restricted from publishing on cyfr.run."
          )

        {:error, :invalid_access_token} ->
          # IdP token expired between OAuth callback and accept submit.
          conn
          |> PendingProbe.clear()
          |> redirect(to: "/login")

        {:error, err} ->
          # 502: cyfr.run refused or misanswered the accept — a 200 said
          # "fine" about a failure. Internal terms are logged, never shown.
          Logger.error("[LegalAcceptController] accept_policies error: #{inspect(err)}")
          error_page(conn, 502, accept_error_message(err))
      end
    end
  end

  def submit(conn, _params), do: error_page(conn, 400, "policy_version is required")

  # ============================================================================
  # Helpers
  # ============================================================================

  # One outbound call per policy used to run sequentially on every GET —
  # 1+N round-trips to cyfr.run before the page painted. The bodies are
  # immutable per policy_version, so they memoize on it; a cold read
  # fetches them concurrently.
  @bodies_ttl_ms :timer.minutes(10)

  defp fetch_all_bodies(version, policies) when is_list(policies) do
    case Arca.Cache.get({:legal_bodies, version}) do
      {:ok, bodies} ->
        bodies

      :miss ->
        bodies =
          policies
          |> Task.async_stream(
            fn %{"name" => name, "title" => title} ->
              case Client.get_legal_page(name) do
                {:ok, %{"content_markdown" => md}} -> {name, title, md}
                _ -> {name, title, "_(failed to load #{name})_"}
              end
            end,
            ordered: true,
            timeout: 15_000,
            on_timeout: :kill_task
          )
          |> Enum.zip(policies)
          |> Enum.map(fn
            {{:ok, body}, _policy} ->
              body

            {_, %{"name" => name, "title" => title}} ->
              {name, title, "_(failed to load #{name})_"}
          end)

        # A page that failed to load is not worth pinning for 10 minutes.
        if Enum.all?(bodies, fn {_, _, md} -> not String.starts_with?(md, "_(failed") end) do
          Arca.Cache.put({:legal_bodies, version}, bodies, @bodies_ttl_ms)
        end

        bodies
    end
  end

  defp fetch_all_bodies(_version, _), do: []

  defp all_acknowledged?(params) do
    names = String.split(params["policies"] || "", ",", trim: true)

    Enum.all?(names, fn name ->
      ack_field = "ack_" <> String.replace(name, "-", "_")
      params[ack_field] == "on"
    end)
  end

  defp current_provider(conn), do: PendingProbe.current_provider(conn)

  defp current_provider(conn, params), do: {:ok, PendingProbe.current_provider(conn, params)}

  defp accept_error_message(%Compendium.OCI.Errors{} = err),
    do: Compendium.MCP.Shared.to_error_string(err)

  defp accept_error_message(msg) when is_binary(msg), do: msg
  defp accept_error_message(_), do: "The acceptance could not be recorded — try again."

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
