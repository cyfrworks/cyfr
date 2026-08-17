# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ClaimNamespaceController do
  @moduledoc """
  Handles the personal-namespace claim gate for web-browser sessions.

  - `GET /claim-namespace` — renders a form prompting the user for a slug
    (default = suggested username from the OAuth provider login).
  - `POST /claim-namespace/submit` — decrypts the `_cyfr_pending_probe`
    cookie, invokes `Compendium.Registry.Client.claim_personal_namespace/4`,
    stores the issued push token, and redirects to the configured post-login
    landing target via `EmissaryWeb.SafeRedirect`.

  Accepted cross-layer coupling — this controller is part of the auth
  sliver in spirit but calls Compendium for the post-claim token storage.
  """

  use PrismWeb, :controller

  require Logger

  alias Compendium.Registry.Client
  alias Compendium.Registry.CredentialStore

  def show(conn, _params) do
    suggested = get_session(conn, :claim_suggested_username) || ""
    page(conn, 200, suggested, nil)
  end

  def submit(conn, %{"username" => raw_username} = params) when is_binary(raw_username) do
    # Trim whitespace before sending to cyfr.run — its regex rejects padding
    # with a confusing 400 INVALID_USERNAME otherwise.
    username = String.trim(raw_username)

    with {:ok, conn, access_token} <- pop_pending_probe(conn),
         {:ok, user_id} <- current_user_id(conn),
         {:ok, provider} <- current_provider(conn, params),
         {:ok, body} <-
           Client.claim_personal_namespace(username, provider, access_token) do
      slug = body["slug"] || username
      token = body["token"]
      registry = Compendium.Registry.canonical_host()

      cond do
        not is_binary(token) ->
          # Server returned success but omitted the token field. Treat as a
          # local-store failure so the user retries rather than landing on a
          # dashboard without a usable push credential.
          Logger.error(
            "[ClaimNamespaceController] claim succeeded for #{slug} but " <>
              "response omitted `token`; refusing to mark claim-gate passed"
          )

          send_store_error_page(conn, username)

        true ->
          cred = %{
            type: :push_token,
            token: token,
            namespace: slug,
            role: "personal",
            issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            label: Client.device_label()
          }

          case CredentialStore.put(user_id, registry, slug, cred) do
            :ok ->
              # Prime the cache so the next request exits the gate immediately.
              EmissaryWeb.Plugs.PersonalNamespaceCache.put_claimed(user_id, registry)
              # The namespace is the person's athanor slug: mint it now.
              _ = Sanctum.Provisioning.after_sign_in(user_id)

              conn
              |> clear_pending_probe()
              |> delete_session(:claim_suggested_username)
              |> EmissaryWeb.SafeRedirect.post_login()

            {:error, reason} ->
              Logger.error(
                "[ClaimNamespaceController] CredentialStore.put failed for " <>
                  "#{user_id}/#{slug}: #{inspect(reason)}. Namespace is claimed on " <>
                  "cyfr.run but local credential is missing; user must re-login."
              )

              send_store_error_page(conn, username)
          end
      end
    else
      {:expired, conn} ->
        page(conn, 400, username, "Login session expired. Please re-authenticate and try again.")

      {:not_logged_in, conn} ->
        conn
        |> put_status(:unauthorized)
        |> redirect(to: "/auth/github")

      {:error, :invalid_access_token} ->
        # IdP access_token expired between the callback-side cookie stash and
        # the claim submission. Can't recover; bounce back through OAuth.
        # Clear the dead cookie so the fresh auth round starts clean.
        provider_for_redirect =
          case params["provider"] do
            p when p in ["github", "google"] -> p
            _ -> "github"
          end

        conn
        |> clear_pending_probe()
        |> redirect(to: "/auth/#{provider_for_redirect}")

      {:error, %Compendium.OCI.Errors{reason: :policy_acceptance_required}} ->
        # cyfr.run wants the user to clickwrap-accept the current bundled
        # policy before claiming. Don't clear _cyfr_pending_probe — the
        # accept flow consumes it, and the user can return here to retry
        # the claim.
        conn
        |> redirect(to: "/legal/accept")

      {:error, err} ->
        msg =
          case err do
            %Compendium.OCI.Errors{} -> Compendium.OCI.Errors.to_string(err)
            b when is_binary(b) -> b
            other -> inspect(other)
          end

        page(conn, 200, username, msg)
    end
  end

  def submit(conn, _params), do: page(conn, 400, "", "username is required")

  # ============================================================================
  # Internal
  # ============================================================================

  # Renders a 500 page when the claim succeeded server-side but the local
  # credential store write failed. Session keys are preserved so the user can
  # retry without losing OAuth-redirect context. UX hint directs them to
  # re-login rather than refresh-loop on the same dead cookie.
  defp send_store_error_page(conn, username) do
    page(
      conn,
      500,
      username,
      "Namespace claimed on cyfr.run but we couldn't save the credential locally. " <>
        "Please sign out and sign back in to retry."
    )
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

  # Reads (but does NOT delete) the encrypted `_cyfr_pending_probe` cookie.
  # `AuthController.maybe_stash_pending_probe/3` writes it with `encrypt: true`
  # (the value is a provider access token — plaintext in a signed cookie would
  # leak it to anyone who reads the jar), so it must be fetched as `encrypted:`;
  # fetching it `signed:` fails verification and reads as nil. The caller must
  # call `clear_pending_probe/1` on the success path — a failed claim (e.g.
  # `slug_taken` 409) re-renders the form and the user retries with the same
  # access_token. Deleting here would doom the retry to 400 "Login session
  # expired" after a single typo.
  defp pop_pending_probe(conn) do
    conn = fetch_cookies(conn, encrypted: ["_cyfr_pending_probe"])

    case conn.cookies["_cyfr_pending_probe"] do
      token when is_binary(token) and token != "" ->
        {:ok, conn, token}

      _ ->
        {:expired, conn}
    end
  end

  defp clear_pending_probe(conn) do
    delete_resp_cookie(conn, "_cyfr_pending_probe")
  end

  defp current_user_id(conn) do
    case get_session(conn, :sanctum_session_token) do
      token when is_binary(token) and token != "" ->
        case Sanctum.Session.load(token, surface: :console) do
          {:ok, %{user_id: id}} -> {:ok, id}
          _ -> {:not_logged_in, conn}
        end

      _ ->
        {:not_logged_in, conn}
    end
  end

  defp current_provider(_conn, %{"provider" => p}) when p in ["github", "google"], do: {:ok, p}

  defp current_provider(conn, _params) do
    case Sanctum.Session.load(get_session(conn, :sanctum_session_token) || "", surface: :console) do
      {:ok, %{provider: p}} when p in ["github", "google"] -> {:ok, p}
      _ -> {:ok, "github"}
    end
  end
end
