defmodule EmissaryWeb.OAuthCallbackController do
  @moduledoc """
  Handles OAuth callback redirects for catalyst OAuth providers.

  This is separate from the user authentication OAuth flow (AuthController).
  It handles code exchange for catalyst component tokens.

  Security: Uses `Context.local()` because the `state` parameter proves the
  flow was initiated by a legitimate user (random, one-time use, 10-minute TTL).
  """

  use EmissaryWeb, :controller

  def callback(conn, %{"code" => code, "state" => state}) do
    redirect_uri = EmissaryWeb.Endpoint.url() <> "/auth/oauth/callback"

    case Sanctum.OAuth.exchange_code(Sanctum.Context.local(), state, code, redirect_uri) do
      {:ok, result} ->
        send_callback_html(conn, 200, success_html(result.provider, result.component_ref))

      {:error, reason} ->
        send_callback_html(conn, 400, error_html("Authorization failed", to_string(reason)))
    end
  end

  def callback(conn, %{"error" => error}) do
    send_callback_html(conn, 400, error_html("Authorization denied", error))
  end

  def callback(conn, _params) do
    send_callback_html(conn, 400, error_html("Invalid callback", "Missing authorization parameters. Please try again."))
  end

  # Override the endpoint's `default-src 'none'` CSP to allow inline styles
  # for this HTML response. This is a one-off browser-facing page (post-OAuth
  # redirect), not an API endpoint, so relaxing CSP here is safe.
  defp send_callback_html(conn, status, html) do
    conn
    |> put_resp_header("content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'")
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
  end

  # -- HTML responses --

  defp success_html(provider, component_ref) do
    provider_display = provider |> to_string() |> String.capitalize()

    callback_html(
      "Authorization Complete",
      """
      <div class="icon">&#10003;</div>
      <h1>Connected to #{html_escape(provider_display)}</h1>
      <p class="detail">#{html_escape(component_ref)}</p>
      <p>You can close this window and return to your terminal.</p>
      """,
      "#10b981"
    )
  end

  defp error_html(title, message) do
    callback_html(
      title,
      """
      <div class="icon">&#10007;</div>
      <h1>#{html_escape(title)}</h1>
      <p>#{html_escape(message)}</p>
      <p>Close this window and try again.</p>
      """,
      "#ef4444"
    )
  end

  defp callback_html(title, body, accent_color) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>CYFR &mdash; #{html_escape(title)}</title>
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
          background: #0a0a0a;
          color: #e5e5e5;
          display: flex;
          align-items: center;
          justify-content: center;
          min-height: 100vh;
        }
        .card {
          text-align: center;
          max-width: 420px;
          padding: 3rem 2rem;
        }
        .icon {
          font-size: 3rem;
          width: 5rem;
          height: 5rem;
          line-height: 5rem;
          border-radius: 50%;
          background: #{accent_color}18;
          color: #{accent_color};
          margin: 0 auto 1.5rem;
        }
        h1 {
          font-size: 1.25rem;
          font-weight: 600;
          margin-bottom: 0.75rem;
        }
        p {
          color: #a3a3a3;
          font-size: 0.9rem;
          line-height: 1.5;
          margin-bottom: 0.5rem;
        }
        .detail {
          font-family: ui-monospace, "SF Mono", monospace;
          font-size: 0.8rem;
          color: #737373;
          margin-bottom: 1rem;
        }
      </style>
    </head>
    <body>
      <div class="card">
        #{body}
      </div>
    </body>
    </html>
    """
  end

  defp html_escape(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
