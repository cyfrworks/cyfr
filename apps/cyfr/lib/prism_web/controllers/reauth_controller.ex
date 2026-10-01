# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ReauthController do
  @moduledoc """
  The issuer's answer to a re-authentication for one pending confirmation
  (`GET /auth/oidcc/reauth`, the redirect URI the issuer lists beside the
  sign-in callback), and the person's answer to what it confirms
  (`POST /auth/oidcc/reauth`).

  `Sanctum.Auth.OIDC.reauth_callback/1` verifies the fresh login: the
  state names the record under this home's keyed digest, and the ID token
  must carry the record's nonce, an `auth_time` at or after its opening,
  and the issuer and subject of the person's own linked door. It confirms
  nothing. The page shows the record's preview, what the change would do
  as the home stored it, and asks the person to approve or decline; the
  verified proof waits under a single-use ticket this browser's cookie
  session holds, never the page.

  The answer is a POST the browser pipeline's CSRF token guards.
  `Sanctum.Auth.OIDC.reauth_decide/3` spends the ticket whatever the
  answer, and an approval confirms the record only when this browser's
  own session is the record's person: a decline, another person's
  session or none confirms nothing. The asking client sees the record
  confirmed through the confirmation stream and repeats its change.
  """

  use PrismWeb, :controller

  alias CyfrWeb.MinimalPage
  alias CyfrWeb.SignInResponse

  @ticket_key "oidc_reauth_ticket"

  @doc "Verify the issuer's answer and show what it would confirm (the module doc)."
  def callback(conn, params) do
    case Sanctum.Auth.OIDC.reauth_callback(params) do
      {:ok, held} ->
        conn
        |> put_session(@ticket_key, held.ticket)
        |> preview_page(held)

      {:error, :unavailable} ->
        unavailable(conn)

      {:error, reason} when reason in [:not_pending, :expired] ->
        nothing_to_confirm(conn)

      {:error, _refused} ->
        page(
          conn,
          401,
          "Not confirmed",
          "The fresh sign-in did not confirm this change: it must be a new sign-in, as the " <>
            "person who asked, for this confirmation."
        )
    end
  end

  @doc "The person's approval or decline of the change the page showed (the module doc)."
  def decide(conn, params) do
    ticket = get_session(conn, @ticket_key)
    session = get_session(conn, SignInResponse.session_key())
    conn = delete_session(conn, @ticket_key)

    case {params["decision"], ticket} do
      {decision, ticket} when decision in ["approve", "decline"] and is_binary(ticket) ->
        answer(conn, Sanctum.Auth.OIDC.reauth_decide(ticket, session, decided(decision)))

      _malformed ->
        answer(conn, {:error, :reauth_refused})
    end
  end

  defp decided("approve"), do: :approve
  defp decided("decline"), do: :decline

  defp answer(conn, {:ok, :declined}) do
    page(
      conn,
      200,
      "Not confirmed",
      "You declined. Nothing was confirmed, and the change does not go ahead."
    )
  end

  defp answer(conn, {:ok, _confirmed}) do
    conn
    |> SignInResponse.put_flash_if_available(
      :info,
      "Confirmed. The change you asked for can go ahead."
    )
    |> redirect(to: "/")
  end

  defp answer(conn, {:error, :another_person}) do
    page(
      conn,
      403,
      "Not confirmed",
      "This browser is not signed in here as the person who asked for this change, so " <>
        "nothing was confirmed. Sign in as that person and ask for the change again."
    )
  end

  defp answer(conn, {:error, :unavailable}), do: unavailable(conn)

  defp answer(conn, {:error, reason}) when reason in [:not_pending, :expired],
    do: nothing_to_confirm(conn)

  defp answer(conn, {:error, _refused}) do
    page(
      conn,
      409,
      "Not confirmed",
      "This sign-in no longer confirms anything: it was answered already, expired, or the " <>
        "change was asked for again. Nothing was confirmed."
    )
  end

  defp unavailable(conn),
    do: page(conn, 503, "Try again shortly", "The confirmation could not be read just now.")

  defp nothing_to_confirm(conn) do
    page(
      conn,
      409,
      "Nothing to confirm",
      "This confirmation is no longer waiting for a proof. Ask for the change again."
    )
  end

  # What the change would do, as the home stored its preview, and the two
  # answers, each a form the CSRF token guards.
  defp preview_page(conn, held) do
    preview = held.preview
    token = Plug.CSRFProtection.get_csrf_token()

    facts =
      [
        {"Change", held.operation},
        {"On", preview["resource"]},
        {"Athanor", preview["athanor"]},
        {"Home", preview["home"]}
      ] ++ details(preview["details"])

    rows =
      for {label, value} <- facts, is_binary(value) and value != "" do
        ["<p class=\"detail\">", MinimalPage.h(label), ": ", MinimalPage.h(value), "</p>"]
      end

    form = fn decision, label ->
      [
        "<form method=\"post\" action=\"/auth/oidcc/reauth\" style=\"display:inline-block;margin:0.5rem\">",
        "<input type=\"hidden\" name=\"_csrf_token\" value=\"",
        MinimalPage.h(token),
        "\">",
        "<input type=\"hidden\" name=\"decision\" value=\"",
        decision,
        "\">",
        "<button type=\"submit\">",
        label,
        "</button></form>"
      ]
    end

    MinimalPage.send_page(
      conn,
      200,
      "Confirm this change?",
      [
        "<p>You signed in again to confirm a change. Approve it only if you asked for it.</p>",
        rows,
        form.("approve", "Approve"),
        form.("decline", "Decline")
      ]
    )
  end

  defp details(details) when is_map(details) do
    details
    |> Enum.sort()
    |> Enum.map(fn
      {key, values} when is_list(values) -> {key, Enum.join(values, ", ")}
      {key, value} -> {key, value}
    end)
  end

  defp details(_none), do: []

  defp page(conn, status, title, sentence) do
    MinimalPage.send_page(
      conn,
      status,
      title,
      "<p>#{MinimalPage.h(sentence)}</p><p><a href=\"/\">Back</a></p>"
    )
  end
end
