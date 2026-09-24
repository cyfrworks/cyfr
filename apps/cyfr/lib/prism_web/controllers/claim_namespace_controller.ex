# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ClaimNamespaceController do
  @moduledoc """
  The publisher-namespace claim for web-browser sessions: a person who
  wants to publish to cyfr.run claims their namespace here, whenever they
  choose. Signing in never depends on it.

  - `GET /claim-namespace` — renders a form prompting the user for a slug
    (default = a suggestion from their screen name or email).
  - `POST /claim-namespace/submit` — reads the pending-probe cookie
    (`PrismWeb.PendingProbe`), invokes
    `Compendium.Registry.Client.claim_personal_namespace/4`,
    stores the issued push token, and redirects to the configured post-login
    landing target via `PrismWeb.SafeRedirect`.

  Accepted cross-layer coupling — this controller is part of the auth
  sliver in spirit but calls Compendium for the post-claim token storage.
  """

  use PrismWeb, :controller

  require Logger

  alias Compendium.Registry.Client
  alias Compendium.Registry.CredentialStore
  alias PrismWeb.PendingProbe

  def show(conn, _params) do
    page(conn, 200, suggestion(conn), nil)
  end

  def submit(conn, %{"username" => raw_username} = params) when is_binary(raw_username) do
    # Trim whitespace before sending to cyfr.run — its regex rejects padding
    # with a confusing 400 INVALID_USERNAME otherwise.
    username = String.trim(raw_username)

    # `popped` rather than rebinding `conn`: `with` does not export its
    # bindings to `else`, so every arm below answers on the conn this
    # function was called with. Naming them apart keeps that a decision
    # instead of a surprise the day a clause above starts assigning.
    with {:ok, popped, access_token} <- PendingProbe.pop(conn),
         {:ok, ctx} <- standing_caller(popped),
         {:ok, provider} <- current_provider(popped, params),
         {:ok, body} <-
           Client.claim_personal_namespace(username, provider, access_token),
         # The registry answered after a round trip: the session is read
         # again before anything is written under it.
         {:ok, %{user_id: user_id} = fresh} <- still_standing(popped, ctx) do
      conn = popped
      slug = body["slug"] || username

      # The claim is the person's identity from here on: it lands on the
      # users row first, and that is what lets them through. The push token
      # is cached best-effort — a later probe re-mints it.
      case Sanctum.SignIn.record_namespace(user_id, slug) do
        {:ok, _user} ->
          registry = Compendium.RegistryHost.canonical_host()

          conn =
            case CredentialStore.put_push_token(
                   fresh,
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
          |> PrismWeb.SafeRedirect.post_login()

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

      {:unavailable, conn} ->
        page(
          conn,
          503,
          username,
          "We could not confirm your session just now. Try again shortly."
        )

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
      pattern: Prima.ComponentRef.personal_slug_html_pattern()
    )
  end

  # One renderer: a registry's own error becomes its refusal first
  # (`Compendium.Providers.Shared.refusal/1`), and an internal term reads
  # as the fixed sentence, never reflected.
  defp claim_error_message(other),
    do: other |> Compendium.Providers.Shared.refusal() |> Grimoire.Error.render()

  defp suggestion(conn) do
    with {:ok, %{user_id: id, provider: provider}} when is_binary(id) <-
           Sanctum.Caller.peek(get_session(conn, PrismWeb.SignInResponse.session_key())),
         {:ok, user} <- Sanctum.Tenancy.Users.get(id) do
      Sanctum.SignIn.suggested_slug(user, provider || "github") || ""
    else
      _ -> ""
    end
  end

  # The session the cookie names, established and revalidated against the
  # stored session and the person's standing: the claim writes on that
  # person's row, so a look at who the cookie names is not enough.
  defp standing_caller(conn) do
    token = get_session(conn, PrismWeb.SignInResponse.session_key())

    with {:ok, ctx} <- Sanctum.Caller.establish(token, refresh: false) do
      still_standing(conn, ctx)
    else
      {:error, :unavailable} -> {:unavailable, conn}
      _ -> {:not_logged_in, conn}
    end
  end

  defp still_standing(conn, ctx) do
    case Sanctum.Caller.revalidate_session(ctx) do
      {:ok, %Sanctum.Context{user_id: id} = fresh} when is_binary(id) -> {:ok, fresh}
      {:error, :unavailable} -> {:unavailable, conn}
      _ -> {:not_logged_in, conn}
    end
  end

  defp current_provider(conn, params), do: {:ok, PendingProbe.current_provider(conn, params)}
end
