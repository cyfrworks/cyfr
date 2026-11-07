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

  Every file and `config.json` is answered with an `ETag` of its body (the
  quoted lowercase hex SHA-256 of its bytes), and a request whose
  `If-None-Match` names it, or `*`, is answered `304` with no body and the
  same headers: a revalidation never sends the bundle again.

  The bundle is embedded when this module compiles, each file with its
  ETag computed then, and nothing reads the disk at runtime: each file is
  an `@external_resource`, so a rebuilt bundle recompiles the module. A
  file the build had not produced when it compiled answers `404`.
  """

  use Emissary.Web, :controller

  @root Path.join(:code.priv_dir(:cyfr), "static/account")

  # Each name served, its file in the bundle and its type.
  @names [
    {"new", "new.html", "text/html"},
    {"sign", "sign.html", "text/html"},
    {"add", "add.html", "text/html"},
    {"recover", "recover.html", "text/html"},
    {"devices", "devices.html", "text/html"},
    {"sw.js", "sw.js", "text/javascript"},
    {"account.js", "account.js", "text/javascript"},
    {"account.css", "account.css", "text/css"}
  ]

  for {_name, file, _type} <- @names, do: @external_resource(Path.join(@root, file))

  # Mix recompiles the module when a file changes; runtime never reads
  # the disk for the bundle.
  @bundle (for {name, file, type} <- @names,
               # arca:bypass-ok=C — compile-time embed of the built bundle.
               path = Path.join(@root, file),
               File.exists?(path),
               body = File.read!(path),
               into: %{} do
             etag = ~s(") <> Prima.Digest.sha256_hex(body) <> ~s(")
             {name, %{body: body, type: type, etag: etag}}
           end)

  plug :served

  @doc "`GET /account/:name`."
  def show(conn, %{"name" => "config.json"}) do
    directory = conn.assigns.account_directory

    body =
      Jason.encode!(%{"directory" => directory, "registry" => directory, "policy" => nil})

    answer(conn, body, "application/json", etag(body))
  end

  def show(conn, %{"name" => name}) when is_map_key(@bundle, name) do
    %{body: body, type: type, etag: etag} = Map.fetch!(@bundle, name)
    answer(conn, body, type, etag)
  end

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

  defp etag(body), do: ~s(") <> Prima.Digest.sha256_hex(body) <> ~s(")

  # The body with its digest as ETag, or 304 to a revalidation naming it.
  defp answer(conn, body, type, etag) do
    conn = conn |> put_resp_content_type(type) |> put_resp_header("etag", etag)

    if revalidated?(conn, etag),
      do: send_resp(conn, 304, ""),
      else: send_resp(conn, 200, body)
  end

  # `If-None-Match` names the tag, weakly or not, or names `*`.
  defp revalidated?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("W/", "")))
    |> Enum.any?(&(&1 == etag or &1 == "*"))
  end

  defp not_found(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not Found")
  end
end
