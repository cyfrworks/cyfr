# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AuthController do
  @moduledoc """
  Browser sign-out, and the company sign-in a CYFR may require. A person
  signs in with their account at the sign-in page (`PrismWeb.LoginLive`),
  which sets the session through a one-time ticket
  (`PrismWeb.PasskeyController`).

  ## Routes

  - `POST /auth/logout` - Browser sign-out (cookie session, forgery-guarded)
  - `POST /auth/company` - Begins the company sign-in a CYFR requires
  - `GET /auth/company/callback` - The company issuer's callback

  An API caller's sign-out and session read, by bearer token, are the
  HTTP API's, not the browser's.

  ## The company sign-in

  A CYFR that requires a company sign-in (`Sanctum.CompanyLogin`) refuses
  a person's session for it until they give it, and the company page
  (`PrismWeb.CompanyLoginLive`) posts here, with the browser pipeline's
  CSRF token, under that session (`POST /auth/company`): this action opens
  the attempt and answers `303` to the company's issuer. The issuer
  returns the browser to `GET /auth/company/callback`, which finishes the
  sign-in under the same session and sends the browser to `/` once the
  binding stands, or back to the company page with what went wrong
  (`?error=`). A session that stands goes to `/`, and one refused for
  anything else to the sign-in page. Neither action signs anyone in.
  Every refusal is the request's refused decision, recorded once under
  its sentence with no person or athanor
  (`CyfrWeb.Plugs.CallIdentity.refused/3`).
  """

  use PrismWeb, :controller

  alias CyfrWeb.Plugs.CallIdentity
  alias CyfrWeb.SignInResponse
  alias Sanctum.Session

  @doc """
  Begin the company sign-in for the browser's session (the module doc).
  """
  def company_start(conn, _params) do
    case Sanctum.CompanyLogin.start(get_session(conn, SignInResponse.session_key())) do
      {:ok, url} ->
        conn
        |> put_status(303)
        |> redirect(external: url)

      {:error, reason} when reason in [:standing, :not_required] ->
        redirect(conn, to: "/")

      {:error, reason} when reason in [:unavailable, :identity_stale] ->
        to_company(conn, 503, "unavailable")

      {:error, _refused} ->
        to_login(conn, 401, "Sign in, then sign in with your company.")
    end
  end

  @doc """
  The company issuer's callback (the module doc): the attempt is spent
  whatever follows, and nothing is bound on a refusal.
  """
  def company_callback(conn, params) do
    case Sanctum.CompanyLogin.complete(params, get_session(conn, SignInResponse.session_key())) do
      {:ok, _bound_or_refreshed} ->
        redirect(conn, to: "/")

      {:error, :not_required} ->
        redirect(conn, to: "/")

      {:error, :session_ended} ->
        to_login(
          conn,
          401,
          "Your session ended before the company sign-in finished. Sign in again."
        )

      {:error, :company_subject_bound} ->
        to_company(conn, 409, "subject_bound")

      {:error, :wrong_organization} ->
        to_company(conn, 403, "wrong_organization")

      {:error, :unavailable} ->
        to_company(conn, 503, "unavailable")

      {:error, _refused} ->
        to_company(conn, 403, "refused")
    end
  end

  @doc """
  The browser's sign-out (`POST /auth/logout`): retires the Sanctum
  session the cookie names, drops the cookie session, and lands on the
  sign-in page.

  POST, never GET, so signing someone out is not one `<img src>` away:
  the route's browser pipeline checks the forgery token first.
  """
  def browser_logout(conn, _params) do
    case get_session(conn, SignInResponse.session_key()) do
      token when is_binary(token) and token != "" -> Session.destroy(token)
      _ -> :ok
    end

    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login?error=signed_out")
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Back to the company page, which says what went wrong
  # (`PrismWeb.CompanyLoginLive.sentence/1`).
  defp to_company(conn, status, error) do
    conn
    |> CallIdentity.refused(status, PrismWeb.CompanyLoginLive.sentence(error))
    |> redirect(to: "/company-login?error=" <> error)
  end

  defp to_login(conn, status, message) do
    conn
    |> CallIdentity.refused(status, message)
    |> SignInResponse.put_flash_if_available(:error, message)
    |> redirect(to: "/login")
  end
end
