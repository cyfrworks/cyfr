# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.OAuthCallbackController do
  @moduledoc """
  Handles the OAuth callback for Connection grants (`vault.authorize`).

  This is separate from the user authentication OAuth flow (AuthController).
  It completes the code exchange into a vault entry's token bundle.

  No user Context is required: proof-of-initiation is the single-use,
  unguessable `state` (256-bit, delete-on-read, 2-minute TTL) plus the
  server-held PKCE `code_verifier`. The pending record written when
  `vault.authorize` ran carries the originating athanor and target
  Connection that the resulting tokens are stored under.
  """

  use EmissaryWeb, :controller

  def callback(conn, %{"code" => code, "state" => state}) do
    redirect_uri = EmissaryWeb.Endpoint.url() <> "/auth/oauth/callback"

    case Sanctum.Vault.OAuthGrant.complete(state, code, redirect_uri) do
      {:ok, result} ->
        success_page(conn, result.provider, result.name)

      {:error, :unknown_state} ->
        error_page(conn, "Authorization failed", "invalid or expired state parameter")

      {:error, reason} ->
        error_page(conn, "Authorization failed", fmt_reason(reason))
    end
  end

  def callback(conn, %{"error" => error}) do
    error_page(conn, "Authorization denied", error)
  end

  def callback(conn, _params) do
    error_page(conn, "Invalid callback", "Missing authorization parameters. Please try again.")
  end

  defp fmt_reason(reason) when is_binary(reason), do: reason
  defp fmt_reason(reason) when is_atom(reason), do: to_string(reason)
  defp fmt_reason(reason), do: inspect(reason)

  # Override the endpoint's `default-src 'none'` CSP to allow inline styles
  # for this HTML response. This is a one-off browser-facing page (post-OAuth
  # redirect), not an API endpoint, so relaxing CSP here is safe. The page
  # itself is EmissaryWeb.MinimalPage — the one no-session shell.
  defp send_page(conn, status, title, inner, opts) do
    conn
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"
    )
    |> EmissaryWeb.MinimalPage.send_page(status, title, inner, opts)
  end

  defp success_page(conn, provider, connection_name) do
    provider_display = provider |> to_string() |> String.capitalize()

    send_page(
      conn,
      200,
      "Connected to #{provider_display}",
      """
      <p class="detail">#{EmissaryWeb.MinimalPage.h(connection_name)}</p>
      <p>You can close this window and return to your terminal.</p>
      """,
      icon: "\u2713",
      accent: "#10b981"
    )
  end

  defp error_page(conn, title, message) do
    send_page(
      conn,
      400,
      title,
      """
      <p>#{EmissaryWeb.MinimalPage.h(message)}</p>
      <p>Close this window and try again.</p>
      """,
      icon: "\u2717",
      accent: "#ef4444"
    )
  end

end
