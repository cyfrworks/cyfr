# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.OAuthCallbackController do
  @moduledoc """
  Handles the OAuth callback for vault-entry grants (`vault.authorize`).

  This is separate from the user authentication OAuth flow (AuthController).
  It completes the code exchange into a vault entry's token bundle.

  No user Context is required: proof-of-initiation is the single-use,
  unguessable `state` (256-bit, delete-on-read, 2-minute TTL) plus the
  server-held PKCE `code_verifier`. The pending record written when
  `vault.authorize` ran carries the originating context, athanor and
  target vault entry that the resulting tokens are stored under; the
  grant re-establishes that context's standing before it writes, so a
  session revoked in between writes nothing.

  The callback completes an admission the gate made and decides its own
  refusals, so each error page is also the request's refused decision,
  recorded once with no person or athanor under the class it names
  (`CyfrWeb.Plugs.CallIdentity.refused/2`); a provider's own error text
  is shown on the page and never recorded.
  """

  use Emissary.Web, :controller

  require Logger

  def callback(conn, %{"code" => code, "state" => state}) do
    # The whole URI has one owner now, not just the path: the exchange fails
    # if this differs by so much as a scheme from the one `authorize` sent,
    # and building it here from the endpoint while the grant built it from
    # the public origin is exactly how that happens.
    redirect_uri = Sanctum.Vault.OAuthGrant.redirect_uri()

    case Sanctum.Vault.OAuthGrant.complete(state, code, redirect_uri) do
      {:ok, result} ->
        success_page(conn, result.provider, result.name)

      {:error, :unknown_state} ->
        error_page(conn, :not_found, "Authorization failed", "invalid or expired state parameter")

      {:error, :unauthenticated} ->
        error_page(
          conn,
          :unauthenticated,
          "Authorization failed",
          "the session that started this authorization is no longer signed in here"
        )

      {:error, :unavailable} ->
        error_page(conn, 503, :unavailable, "Authorization failed", "Try again shortly")

      {:error, :scopes_not_requested} ->
        error_page(
          conn,
          :forbidden,
          "Authorization failed",
          "The provider granted scopes this connection did not ask for; nothing was stored."
        )

      {:error, reason} ->
        {class, recorded} = recorded(reason)

        conn
        |> refused(class, recorded)
        |> page_error("Authorization failed", fmt_reason(reason))
    end
  end

  def callback(conn, %{"error" => error}) do
    conn
    |> refused(:forbidden, "the provider denied the authorization")
    |> page_error("Authorization denied", error)
  end

  def callback(conn, _params) do
    error_page(
      conn,
      :invalid_argument,
      "Invalid callback",
      "Missing authorization parameters. Please try again."
    )
  end

  # A typed reason is recorded as its refusal; anything else, a producer's
  # sentence included, as internal under a fixed sentence, so nothing a
  # provider answered reaches the decision record.
  defp recorded(reason) do
    if Sanctum.Refusals.known?(reason) do
      %Prima.Refusal{class: class, message: message} = Sanctum.Refusals.classify(reason)
      {class, message}
    else
      {:internal, "the authorization could not be completed"}
    end
  end

  defp fmt_reason(reason) when is_binary(reason), do: reason
  defp fmt_reason(reason) when is_atom(reason), do: to_string(reason)

  defp fmt_reason(reason) do
    # The rule every other surface applies (`Emissary.MCP.Router`,
    # `PrismWeb.Ops`): an unrecognized term is internal — an exit
    # tuple, a changeset — and is logged, never reflected into the page.
    Logger.warning("[OAuthCallback] grant completion failed: #{inspect(reason)}")
    "the authorization could not be completed"
  end

  # Override the endpoint's `default-src 'none'` CSP to allow inline styles
  # for this HTML response. This is a one-off browser-facing page (post-OAuth
  # redirect), not an API endpoint, so relaxing CSP here is safe. The page
  # itself is CyfrWeb.MinimalPage — the one no-session shell.
  defp send_page(conn, status, title, inner, opts) do
    conn
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"
    )
    |> CyfrWeb.MinimalPage.send_page(status, title, inner, opts)
  end

  defp success_page(conn, provider, connection_name) do
    provider_display = provider |> to_string() |> String.capitalize()

    send_page(
      conn,
      200,
      "Connected to #{provider_display}",
      """
      <p class="detail">#{CyfrWeb.MinimalPage.h(connection_name)}</p>
      <p>You can close this window and return to your terminal.</p>
      """,
      icon: "\u2713",
      accent: "#10b981"
    )
  end

  defp error_page(conn, class, title, message), do: error_page(conn, 400, class, title, message)

  defp error_page(conn, status, class, title, message) do
    conn
    |> refused(class, message)
    |> page_error(status, title, message)
  end

  defp refused(conn, class, message),
    do:
      CyfrWeb.Plugs.CallIdentity.refused(conn, %Prima.Refusal{
        class: class,
        reason: class,
        message: message
      })

  defp page_error(conn, title, message), do: page_error(conn, 400, title, message)

  defp page_error(conn, status, title, message) do
    send_page(
      conn,
      status,
      title,
      """
      <p>#{CyfrWeb.MinimalPage.h(message)}</p>
      <p>Close this window and try again.</p>
      """,
      icon: "\u2717",
      accent: "#ef4444"
    )
  end
end
