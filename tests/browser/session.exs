# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The browser session cookie of a session the release-proof fixture
# created (tests/release-boot/fixture.exs `person`), evaluated inside the
# running server by `bin/cyfr rpc` (`browser_cookie` in
# tests/browser/harness.sh): the endpoint's own session plug signs the
# session token into its cookie, as a sign-in's response does
# (`CyfrWeb.SignInResponse`). Answers one line, `COOKIE=` and the value.

fn [token] ->
  opts = Plug.Session.init(CyfrWeb.Endpoint.session_options())

  conn =
    Plug.Test.conn(:get, "/")
    |> Map.put(:secret_key_base, CyfrWeb.Endpoint.config(:secret_key_base))
    |> Plug.Session.call(opts)
    |> Plug.Conn.fetch_session()
    |> Plug.Conn.put_session(CyfrWeb.SignInResponse.session_key(), token)
    # The session's CSRF state, as the first page a signed-in browser loads
    # writes it (`Plug.CSRFProtection`): the release's cookie is `Secure`,
    # which a browser on this plain-HTTP harness origin would not store
    # again, so the page's token and the socket's check must find it here.
    |> Plug.Conn.put_session("_csrf_token", Base.url_encode64(:crypto.strong_rand_bytes(18)))
    |> Plug.Conn.send_resp(200, "")

  %{value: value} = Map.fetch!(conn.resp_cookies, "_cyfr_key")
  "COOKIE=" <> value
end
