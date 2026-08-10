# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.ScrubTinctureCredentials do
  @moduledoc """
  Redacts tincture credential query params (`_t`, `_key`, `_session`) from
  `conn.query_string` before the response is sent.

  Registered as a `before_send` callback rather than scrubbing on the way in,
  because `Sanctum.TinctureAuth.authenticate/1` reads the credential from the
  query string during the action — it must still be there then, and gone by the
  time anything logs the request.

  A plug rather than a call inside each action: the rate-limit 429, the
  boot-window 503 and the workspace-mismatch 404 all return before the action
  ever touches authentication, and those responses are logged too.

  This is defense in depth for a credential that should not be in a URL at all.
  Operators should also redact these keys at their reverse proxy.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Plug.Conn.register_before_send(conn, &Sanctum.TinctureAuth.scrub_conn/1)
  end
end
