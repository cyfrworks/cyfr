# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.DeviceSessionController do
  @moduledoc """
  A protected command line's session (`Sanctum.DeviceUnlock`): the command
  line's shell proved the person's unlock on its device channel and holds
  a one-time ticket, which it spends here for the session its commands
  carry as `authorization: Bearer`. It is the browser's
  `/auth/device/complete` without the browser: the same ticket, spent once
  through the same `Sanctum.DeviceUnlock.redeem/1`, for the same session,
  bound to the client and slid only by the channel that reserved it, which
  ends with that channel, its lock or its 60-second bound. No cookie is
  read or set, so no CSRF token is asked.

  `POST /device/session` with `{ticket}` answers `200 {session_token,
  expires_at}` (`tests/fixtures/device_unlock.json`, `exchange.http`), the
  expiry in milliseconds since the epoch, `no-store`. A ticket spent, past
  its 60 seconds, locked before it was spent, held by another member, or
  of a device whose standing ended is `403 ticket_refused`; a store that
  cannot answer is `503 unavailable` with a `retry-after` header; a body
  without a ticket is `422 invalid_request`. The ticket and the token are
  redacted from the request log (`Prima.Sanitizer`).
  """

  use Emissary.Web, :controller

  alias CyfrWeb.Plugs.CallIdentity

  @doc "`POST /device/session`."
  def create(conn, %{"ticket" => ticket}) when is_binary(ticket) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case Sanctum.DeviceUnlock.redeem(ticket) do
      {:ok, %{token: token, expires_at: expires_at}} ->
        conn
        |> put_status(200)
        |> json(%{
          session_token: token,
          expires_at: DateTime.to_unix(expires_at, :millisecond)
        })

      {:error, reason} when reason in [:unavailable, :not_owner] ->
        conn
        |> CallIdentity.refused(503, "unavailable")
        |> put_resp_header("retry-after", "1")
        |> put_status(503)
        |> json(%{error: "unavailable"})

      {:error, _refused} ->
        conn
        |> CallIdentity.refused(403, "ticket_refused")
        |> put_status(403)
        |> json(%{error: "ticket_refused"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> CallIdentity.refused(422, "invalid_request")
    |> put_status(422)
    |> json(%{error: "invalid_request"})
  end
end
