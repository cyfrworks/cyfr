# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.AccountControllerTest do
  @moduledoc """
  The account pages the directory's writer serves, through the endpoint,
  from the bundle embedded when the controller compiled: exactly the five
  pages at their names without the extension, the service worker, script
  and style, each the built file's bytes, and `config.json` naming this
  CYFR as directory and registry with no policy; every answer with the
  pages' referrer policy, cache policy and content security policy, and an
  ETag of its body that a revalidation is answered `304` by; anything else
  under `/account`, and every page on a node that is not the directory's
  writer, `404`.
  """

  # The directory setting and this node's public URL are process-wide.
  use CyfrWeb.ConnCase, async: false

  @directory "https://dir.example"
  @root Path.join(:code.priv_dir(:cyfr), "static/account")
  @pages ~w(new sign add recover devices)
  @assets [
    {"sw.js", "text/javascript"},
    {"account.js", "text/javascript"},
    {"account.css", "text/css"}
  ]

  setup do
    Prima.Test.Env.put_app_env(:sanctum, :public_url, @directory)
    Cyfr.Test.Settings.put("directory_serve", "writer")
    :ok
  end

  # The built file's bytes, as the bundle holds them.
  defp built(name), do: File.read!(Path.join(@root, name))

  defp assert_headers(conn) do
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=0, must-revalidate"]

    assert get_resp_header(conn, "content-security-policy") == [
             "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self' #{@directory}"
           ]
  end

  defp content_type(conn), do: conn |> get_resp_header("content-type") |> hd()

  test "each page is its .html file at its name without the extension, with the pages' headers",
       %{conn: conn} do
    for page <- @pages do
      served = get(build_conn(), "/account/#{page}")
      assert served.status == 200, page
      assert served.resp_body == built(page <> ".html")
      assert content_type(served) =~ "text/html"
      assert_headers(served)
    end

    assert get(conn, "/account/new").resp_cookies == %{}
  end

  test "the service worker, script and style are served with their types" do
    for {asset, type} <- @assets do
      served = get(build_conn(), "/account/#{asset}")
      assert served.status == 200, asset
      assert served.resp_body == built(asset)
      assert content_type(served) =~ type
      assert_headers(served)
    end
  end

  test "config.json names this CYFR as directory and registry, with no policy", %{conn: conn} do
    served = get(conn, "/account/config.json")

    assert json_response(served, 200) == %{
             "directory" => @directory,
             "registry" => @directory,
             "policy" => nil
           }

    assert_headers(served)
  end

  test "each answer names its body's digest as ETag, and a revalidation naming it is a 304" do
    for name <- ["new", "sw.js", "config.json"] do
      served = get(build_conn(), "/account/#{name}")
      assert served.status == 200, name

      etag =
        ~s(") <> Base.encode16(:crypto.hash(:sha256, served.resp_body), case: :lower) <> ~s(")

      assert get_resp_header(served, "etag") == [etag], name

      for tag <- [etag, "W/" <> etag, ~s("other", ) <> etag, "*"] do
        revalidated =
          build_conn() |> put_req_header("if-none-match", tag) |> get("/account/#{name}")

        assert revalidated.status == 304, "#{name} #{tag}"
        assert revalidated.resp_body == ""
        assert get_resp_header(revalidated, "etag") == [etag]
        assert_headers(revalidated)
      end
    end

    # A revalidation naming another body's tag answers the body whole,
    # under its own tag.
    old = ~s(") <> Base.encode16(:crypto.hash(:sha256, "<p>new</p>"), case: :lower) <> ~s(")
    changed = build_conn() |> put_req_header("if-none-match", old) |> get("/account/new")
    assert changed.status == 200
    assert changed.resp_body == built("new.html")

    assert get_resp_header(changed, "etag") ==
             [
               ~s(") <>
                 Base.encode16(:crypto.hash(:sha256, built("new.html")), case: :lower) <> ~s(")
             ]

    assert_headers(changed)
  end

  test "nothing else is served under /account" do
    for name <- ["new.html", "secret.txt", "index", "sw", "..", "%2e%2e%2fconfig.exs"] do
      refused = get(build_conn(), "/account/#{name}")
      assert refused.status == 404, name
      assert_headers(refused)
    end

    # No route serves these: the endpoint's fallback answers 404.
    for path <- ["/account/new/extra", "/account"] do
      assert status(path) == 404, path
    end
  end

  # The status the endpoint answers, whether a route answers or none does.
  defp status(path) do
    get(build_conn(), path).status
  rescue
    error -> Plug.Exception.status(error)
  end

  test "a node that is not its directory's writer serves no page" do
    for mode <- ["mirror", "off"] do
      Cyfr.Test.Settings.put("directory_serve", mode)

      for name <- ["new", "sw.js", "config.json"] do
        assert get(build_conn(), "/account/#{name}").status == 404, "#{mode} #{name}"
      end
    end
  end
end
