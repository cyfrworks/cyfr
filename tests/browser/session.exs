# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# A browser session cookie and the session it holds, evaluated inside the
# running server by `bin/cyfr rpc` (tests/browser/harness.sh):
#
#   TOKEN
#       The cookie of a session the release-proof fixture created
#       (tests/release-boot/fixture.exs `person`), for `browser_cookie`:
#       the endpoint's own session plug signs the session token into its
#       cookie, as a sign-in's response does (`CyfrWeb.SignInResponse`).
#       Answers one line, `COOKIE=` and the value.
#
#   read COOKIE
#       The session a browser that signed in holds in its cookie, for
#       `browser_session`: the token the same plug reads from it, the
#       person and the athanor that session is focused on, and that
#       athanor's route segment. Answers one line, `SESSION=` and a JSON
#       object.

fn
  ["read", cookie] ->
    opts = Plug.Session.init(CyfrWeb.Endpoint.session_options())

    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:secret_key_base, CyfrWeb.Endpoint.config(:secret_key_base))
      |> Plug.Test.put_req_cookie("_cyfr_key", cookie)
      |> Plug.Session.call(opts)
      |> Plug.Conn.fetch_session()

    token = Plug.Conn.get_session(conn, to_string(CyfrWeb.SignInResponse.session_key()))
    {:ok, ctx} = Sanctum.Caller.establish({:session, token})
    {:ok, athanor} = Sanctum.Tenancy.Athanors.get(ctx.athanor_id)

    "SESSION=" <>
      Jason.encode!(%{
        token: token,
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        segment: "@" <> athanor.slug
      })

  [token] ->
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
