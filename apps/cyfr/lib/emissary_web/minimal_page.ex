# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.MinimalPage do
  @moduledoc """
  The one no-session HTML shell.

  Login-flow refusals, OAuth-callback results and sign-in-unavailable
  pages render here — the person has no session, so none of the console
  is theirs to see, and the page must stand alone. Three hand-rolled
  shells used to serve one login flow in three themes (two light `#222`
  heredocs and a dark card), and one of them hand-rolled its own HTML
  escaper that missed `&#39;`. One shell, in the console's own dark
  palette; every dynamic value goes through `h/1`.
  """

  import Plug.Conn

  @doc "Escape a dynamic value for interpolation into a page."
  @spec h(term()) :: iodata()
  def h(value), do: Plug.HTML.html_escape(to_string(value))

  @doc """
  Send a standalone page. `inner_html` is trusted markup — escape every
  dynamic value in it with `h/1` at the call site.

  Options: `:icon` (a glyph shown in a tinted disc) and `:accent` (its
  hex color, default `#22d3ee`).
  """
  @spec send_page(Plug.Conn.t(), pos_integer(), String.t(), iodata(), keyword()) :: Plug.Conn.t()
  def send_page(conn, status, title, inner_html, opts \\ []) do
    icon =
      case Keyword.get(opts, :icon) do
        nil ->
          ""

        glyph ->
          accent = safe_accent(Keyword.get(opts, :accent))

          ~s(<div class="icon" style="background: #{accent}18; color: #{accent}">#{h(glyph)}</div>)
      end

    body = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>CYFR &mdash; #{h(title)}</title>
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
        .card { text-align: center; max-width: 420px; padding: 3rem 2rem; }
        .icon {
          font-size: 3rem;
          width: 5rem;
          height: 5rem;
          line-height: 5rem;
          border-radius: 50%;
          margin: 0 auto 1.5rem;
        }
        h1 { font-size: 1.25rem; font-weight: 600; margin-bottom: 0.75rem; }
        p { color: #a3a3a3; font-size: 0.9rem; line-height: 1.5; margin-bottom: 0.5rem; }
        a { color: #22d3ee; }
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
        #{icon}
        <h1>#{h(title)}</h1>
        #{inner_html}
      </div>
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, body)
  end

  # The accent lands inside a style attribute — only a literal hex color
  # may pass, whatever the caller was handed.
  defp safe_accent(accent) when is_binary(accent) do
    if Regex.match?(~r/^#[0-9a-fA-F]{3,8}$/, accent), do: accent, else: "#22d3ee"
  end

  defp safe_accent(_), do: "#22d3ee"
end
