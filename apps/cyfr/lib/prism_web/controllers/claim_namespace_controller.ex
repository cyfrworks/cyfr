# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ClaimNamespaceController do
  @moduledoc """
  Handles the personal-namespace claim gate for web-browser sessions.

  - `GET /claim-namespace` — renders a form prompting the user for a slug
    (default = suggested username from the OAuth provider login).
  - `POST /claim-namespace/submit` — reads the pending-probe cookie
    (`PrismWeb.PendingProbe`), invokes
    `Compendium.Registry.Client.claim_personal_namespace/4`,
    stores the issued push token, and redirects to the configured post-login
    landing target via `EmissaryWeb.SafeRedirect`.

  Accepted cross-layer coupling — this controller is part of the auth
  sliver in spirit but calls Compendium for the post-claim token storage.
  """

  use PrismWeb, :controller

  require Logger

  alias Compendium.Registry.Client
  alias Compendium.Registry.CredentialStore
  alias PrismWeb.PendingProbe

  def show(conn, _params) do
    suggested = get_session(conn, :claim_suggested_username) || ""
    page(conn, 200, suggested, nil)
  end

  def submit(conn, %{"username" => raw_username} = params) when is_binary(raw_username) do
    # Trim whitespace before sending to cyfr.run — its regex rejects padding
    # with a confusing 400 INVALID_USERNAME otherwise.
    username = String.trim(raw_username)

    with {:ok, conn, access_token} <- PendingProbe.pop(conn),
         {:ok, user_id} <- current_user_id(conn),
         {:ok, provider} <- current_provider(conn, params),
         {:ok, body} <-
           Client.claim_personal_namespace(username, provider, access_token) do
      slug = body["slug"] || username

      # The claim is the person's identity from here on: it lands on the
      # users row first, and that is what lets them through. The push token
      # is cached best-effort — a later probe re-mints it.
      case Sanctum.SignIn.record_namespace(user_id, slug) do
        {:ok, _user} ->
          registry = Compendium.RegistryHost.canonical_host()

          conn =
            case CredentialStore.put_push_token(
                   user_id,
                   registry,
                   slug,
                   body["token"],
                   "personal"
                 ) do
              :ok ->
                conn

              _ ->
                Logger.warning(
                  "[ClaimNamespaceController] push token for #{user_id}/#{slug} was not " <>
                    "cached — a later probe re-mints it"
                )

                put_flash(
                  conn,
                  :error,
                  "Your namespace is claimed; the push credential didn't sync yet — " <>
                    "it is re-minted at your next sign-in or `cyfr registry probe`."
                )
            end

          conn
          |> PendingProbe.clear()
          |> delete_session(:claim_suggested_username)
          |> EmissaryWeb.SafeRedirect.post_login()

        {:error, reason} ->
          Logger.error(
            "[ClaimNamespaceController] namespace #{slug} claimed on cyfr.run for " <>
              "#{user_id} but not recorded locally: #{inspect(reason)}"
          )

          send_store_error_page(conn, username, reason)
      end
    else
      {:expired, conn} ->
        page(conn, 400, username, "Login session expired. Please re-authenticate and try again.")

      {:not_logged_in, conn} ->
        conn
        |> put_status(:unauthorized)
        |> redirect(to: "/login")

      {:error, :invalid_access_token} ->
        # IdP access_token expired between the callback-side cookie stash and
        # the claim submission. Can't recover; bounce back through login.
        # Clear the dead cookie so the fresh auth round starts clean.
        conn
        |> PendingProbe.clear()
        |> redirect(to: "/login")

      {:error, %Compendium.OCI.Errors{reason: :policy_acceptance_required}} ->
        # cyfr.run wants the user to clickwrap-accept the current bundled
        # policy before claiming. Don't clear _cyfr_pending_probe — the
        # accept flow consumes it, and the user can return here to retry
        # the claim.
        conn
        |> redirect(to: "/legal/accept")

      {:error, err} ->
        # 422: the claim was refused and the form re-renders for a retry —
        # a 200 said "fine" about a failure. Internal terms are logged,
        # never put on the page.
        page(conn, 422, username, claim_error_message(err))
    end
  end

  def submit(conn, _params), do: page(conn, 400, "", "username is required")

  # ============================================================================
  # Internal
  # ============================================================================

  # Renders a 500 page when the claim succeeded on cyfr.run but the users
  # row could not record it. Session keys are preserved; the next sign-in
  # probes the registry, finds the claim, and records it then.
  defp send_store_error_page(conn, username, reason) do
    detail =
      case reason do
        :namespace_owned_by_another_identity ->
          "another identity on this server already holds that namespace — ask the operator."

        _ ->
          "we couldn't record it locally. Sign out and sign back in to retry."
      end

    page(conn, 500, username, "Namespace claimed on cyfr.run but " <> detail)
  end

  # The one page this controller renders — the form, in the Prism root
  # layout the :browser pipeline set, with or without an error line.
  defp page(conn, status, suggested, error) do
    conn
    |> put_status(status)
    |> render(:show,
      suggested: suggested,
      error: error,
      csrf_token: Plug.CSRFProtection.get_csrf_token(),
      pattern: Regex.source(Sanctum.ComponentRef.personal_slug_regex())
    )
  end

  defp claim_error_message(%Compendium.OCI.Errors{} = err),
    do: Compendium.MCP.Shared.to_error_string(err)

  defp claim_error_message(msg) when is_binary(msg), do: msg

  defp claim_error_message(other) do
    Logger.error("[ClaimNamespaceController] claim failed: #{inspect(other)}")
    "The claim failed — try again."
  end

  defp current_user_id(conn) do
    case Sanctum.Caller.peek(get_session(conn, EmissaryWeb.SignInResponse.session_key())) do
      {:ok, %{user_id: id}} when is_binary(id) -> {:ok, id}
      _ -> {:not_logged_in, conn}
    end
  end

  defp current_provider(conn, params), do: {:ok, PendingProbe.current_provider(conn, params)}
end
