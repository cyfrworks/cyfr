# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.AccountController do
  @moduledoc """
  The account pages a CYFR serving a directory serves at its origin
  (`ARCHITECTURE.md` §9.1–§9.2): the static bundle the asset build puts in
  `priv/static/account/`, and `config.json`, the directory's one dynamic
  answer. Only the directory's writer serves them
  (`Sanctum.Directory.writer?/0`); every other node answers `404`.

  ## What is served

  Exactly these, under `/account/`, and nothing else (`404`):

    * the pages `new`, `sign`, `add`, `recover` and `devices`, each its
      `.html` file, at its name without the extension;
    * `sw.js`, `account.js` and `account.css`, the bundle's service
      worker, script and style;
    * `config.json`: `{"directory": origin, "registry": origin, "policy":
      null}`. This CYFR is both the directory and the registry beside it
      (`Sanctum.Directory.Handles`), which asks no policy acceptance, so
      there is no policy to accept.

  Every answer carries `Referrer-Policy: no-referrer`, `Cache-Control:
  public, max-age=0, must-revalidate` (the service worker keeps the
  offline copy) and the content security policy `default-src 'none';
  script-src 'self'; style-src 'self'; connect-src 'self' <registry>`,
  the registry being this CYFR's own origin. No session is read and no
  cookie set: the pages take their input from the fragment.
  """

  use Emissary.Web, :controller

  @pages ~w(new sign add recover devices)
  @assets %{
    "sw.js" => "text/javascript",
    "account.js" => "text/javascript",
    "account.css" => "text/css"
  }

  plug :served

  @doc "`GET /account/:name`."
  def show(conn, %{"name" => "config.json"}) do
    directory = conn.assigns.account_directory
    json(conn, %{"directory" => directory, "registry" => directory, "policy" => nil})
  end

  def show(conn, %{"name" => page}) when page in @pages,
    do: file(conn, page <> ".html", "text/html")

  def show(conn, %{"name" => asset}) when is_map_key(@assets, asset),
    do: file(conn, asset, Map.fetch!(@assets, asset))

  def show(conn, _params), do: not_found(conn)

  # The pages are this node's only while it is its directory's writer and
  # its origin is a home; there, every answer, a 404 too, carries the
  # pages' headers.
  defp served(conn, _opts) do
    with true <- Sanctum.Directory.writer?(),
         {:ok, directory} <- Sanctum.Directory.served() do
      conn
      |> headers(directory)
      |> assign(:account_directory, directory)
    else
      _not_served -> conn |> not_found() |> halt()
    end
  end

  defp headers(conn, registry) do
    conn
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("cache-control", "public, max-age=0, must-revalidate")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self' #{registry}"
    )
  end

  # A file of the bundle, by a name from the lists above: a bundle not
  # built here answers 404.
  defp file(conn, name, type) do
    path = Path.join(root(), name)

    if File.regular?(path) do
      conn
      |> put_resp_content_type(type)
      |> send_file(200, path)
    else
      not_found(conn)
    end
  end

  defp not_found(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not Found")
  end

  # Where the asset build puts the bundle. The suite points it at fixture
  # files through `:cyfr, :account_pages_root`, a test seam no
  # configuration file sets.
  defp root do
    Application.get_env(:cyfr, :account_pages_root) ||
      Application.app_dir(:cyfr, "priv/static/account")
  end
end
