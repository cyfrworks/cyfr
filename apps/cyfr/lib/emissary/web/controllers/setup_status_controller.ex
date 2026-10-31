# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.SetupStatusController do
  @moduledoc """
  Whether setup is still open, for a program on this machine that holds
  the setup token: `POST /api/setup/status` (`Prima.SetupStatus`), the
  token as `authorization: Bearer <token>` and nowhere else. The answer is
  `Sanctum.Newcomer.setup_open/1`'s, a read of what a setup would be
  answered now and never authority: the admission decides again in its
  transaction.

  An invalid token, a spent one and an absent one all answer `closed`, so
  the route tells a guesser nothing, and a store that cannot answer is
  `unavailable`, never `closed`. This route makes no session, admits no
  one and writes nothing: its pipeline mints no call identity, so a
  refusal records no decision. `Emissary.Web.Plugs.LocalOnly` admits the
  caller; a request that is not the wire's is refused 400.
  """

  use Emissary.Web, :controller

  @refusal ~s(A setup status request is {"version":1}.)

  @doc "`POST /api/setup/status`."
  def status(conn, _params) do
    if Prima.SetupStatus.request?(conn.body_params) do
      {status, body} =
        conn |> token() |> Sanctum.Newcomer.setup_open() |> state() |> Prima.SetupStatus.answer()

      conn |> put_status(status) |> json(body)
    else
      CyfrWeb.ApiError.refuse(conn, {:invalid_argument, @refusal})
    end
  end

  defp state(:ok), do: :open
  defp state({:error, :setup_closed}), do: :closed
  defp state({:error, :unavailable}), do: :unavailable

  defp token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _absent -> nil
    end
  end
end
