# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.PwaStaticTest do
  @moduledoc """
  The two files that make the chat installable are served un-digested from
  the one endpoint: the web manifest and the service worker. Both are named
  in `EmissaryWeb.static_paths/0`; dropping either would 404 silently.
  """
  use EmissaryWeb.ConnCase, async: true

  test "the manifest and the service worker are served" do
    manifest = get(build_conn(), "/manifest.webmanifest")
    assert manifest.status == 200
    assert Jason.decode!(manifest.resp_body)["start_url"] == "/a"

    sw = get(build_conn(), "/sw.js")
    assert sw.status == 200
    assert sw.resp_body =~ "navigate"
    assert "manifest.webmanifest" in EmissaryWeb.static_paths()
    assert "sw.js" in EmissaryWeb.static_paths()
  end
end
