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
    (`CyfrWeb.PendingProbe`), claims the namespace through the gate
    (`registry.claim_personal`, which records it on the users row and
    stores the issued push token), and redirects to the configured
    post-login landing target via `CyfrWeb.SafeRedirect`; a refusal the
    operation answers is rendered as this page.
  """

  use PrismWeb, :controller

  require Logger

  alias CyfrWeb.PendingProbe

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
         {:ok, provider} <- current_provider(popped, params) do
      # The claim, its users-row record and its push token are the
      # operation's (`registry.claim_personal`), which re-reads the
      # caller's standing after the registry answers and records its
      # decision; the page renders what it answered.
      args = %{"username" => username, "provider" => provider, "access_token" => access_token}

      case PrismWeb.Ops.call_tool(ctx, "registry/claim_personal", args) do
        {:ok, body} -> claimed(popped, body)
        {:error, reason} -> refused(popped, username, reason)
      end
    else
      {:expired, conn} ->
        page(conn, 400, username, "Login session expired. Please re-authenticate and try again.")

      {:not_logged_in, conn} ->
        conn
        |> put_status(:unauthorized)
        |> redirect(to: "/login")

      {:unavailable, conn} ->
        unavailable(conn, username)
    end
  end

  def submit(conn, _params), do: page(conn, 400, "", "username is required")

  # ============================================================================
  # Internal
  # ============================================================================

  # The claim landed on the users row; a push token the operation could not
  # cache, or that the registry did not answer, is re-minted at the next
  # sign-in or probe.
  defp claimed(conn, body) do
    conn =
      if Map.get(body, "local_store_failed") == true or Map.get(body, "token") in [nil, ""] do
        Logger.warning(
          "[ClaimNamespaceController] push token for #{body["slug"]} was not cached — a " <>
            "later probe re-mints it"
        )

        put_flash(
          conn,
          :error,
          "Your namespace is claimed; the push credential didn't sync yet — " <>
            "it is re-minted at your next sign-in or `cyfr registry probe`."
        )
      else
        conn
      end

    conn
    |> PendingProbe.clear()
    |> CyfrWeb.SafeRedirect.post_login()
  end

  # The operation's refusal as this page answers it.
  defp refused(conn, username, reason) do
    case Sanctum.Refusals.classify(reason) do
      # The IdP access_token expired between the callback-side cookie stash
      # and the claim submission: bounce back through login, with the dead
      # cookie cleared so the fresh auth round starts clean.
      %Prima.Refusal{reason: :invalid_access_token} ->
        conn
        |> PendingProbe.clear()
        |> redirect(to: "/login")

      # cyfr.run wants the current policy accepted first. The pending probe
      # stays: the accept flow consumes it, and the claim can be retried.
      %Prima.Refusal{reason: {:registry, :policy_acceptance_required}} ->
        redirect(conn, to: "/legal/accept")

      # The caller stopped standing while the registry answered.
      %Prima.Refusal{reason: :unauthenticated} ->
        conn
        |> put_status(:unauthorized)
        |> redirect(to: "/login")

      %Prima.Refusal{reason: reason} when reason in [:unavailable, :identity_stale] ->
        unavailable(conn, username)

      # Claimed at the registry, but not recorded here: the session stands,
      # and the next sign-in's probe finds and records the claim.
      %Prima.Refusal{reason: {:conflict, message}} ->
        page(conn, 500, username, message)

      %Prima.Refusal{reason: {:unavailable, "Storage"}} ->
        page(
          conn,
          500,
          username,
          "Namespace claimed on cyfr.run but we couldn't record it locally. Sign out and " <>
            "sign back in to retry."
        )

      # 422: the claim was refused and the form re-renders for a retry. The
      # refusal's sentence is what the page shows.
      %Prima.Refusal{message: message} ->
        page(conn, 422, username, message)
    end
  end

  defp unavailable(conn, username),
    do:
      page(conn, 503, username, "We could not confirm your session just now. Try again shortly.")

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

  defp suggestion(conn) do
    with {:ok, %{user_id: id, provider: provider}} when is_binary(id) <-
           Sanctum.Caller.peek(get_session(conn, CyfrWeb.SignInResponse.session_key())),
         {:ok, user} <- Sanctum.Tenancy.Users.get(id) do
      Sanctum.SignIn.suggested_slug(user, provider || "github") || ""
    else
      _ -> ""
    end
  end

  # The session the cookie names, established and revalidated against the
  # stored session and the person's standing: the claim writes on that
  # person's row, so a look at who the cookie names is not enough. A store
  # that cannot answer, and a remote person whose identity could not be
  # confirmed fresh, are a "try again" — the session stands — never a
  # sign-out.
  defp standing_caller(conn) do
    token = get_session(conn, CyfrWeb.SignInResponse.session_key())

    with {:ok, ctx} <- Sanctum.Caller.establish(token, refresh: false),
         {:ok, %Sanctum.Context{user_id: id} = fresh} when is_binary(id) <-
           Sanctum.Caller.revalidate_session(ctx) do
      {:ok, fresh}
    else
      {:error, reason} when reason in [:unavailable, :identity_stale] -> {:unavailable, conn}
      _ -> {:not_logged_in, conn}
    end
  end

  defp current_provider(conn, params), do: {:ok, PendingProbe.current_provider(conn, params)}
end
