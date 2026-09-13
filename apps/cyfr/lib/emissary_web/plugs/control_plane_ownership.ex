# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.ControlPlaneOwnership do
  @moduledoc """
  Refuses every request while this boot does not own the control plane
  (`Cyfr.ControlPlane`): a lease that lapsed unrenewed means another boot
  may hold the database, and a request served here could accept a turn or
  admit an execution that the owner also admits. Health stays reachable so
  a probe can see the state instead of a bare 503.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["api", "health" | _]} = conn, _opts), do: conn

  def call(conn, _opts) do
    if Cyfr.ControlPlane.owner?() do
      conn
    else
      conn
      |> put_resp_header("retry-after", "5")
      |> EmissaryWeb.ApiError.halt(
        503,
        :control_plane_lost,
        "control plane ownership lost; this node refuses work until it reclaims the database"
      )
    end
  end
end
