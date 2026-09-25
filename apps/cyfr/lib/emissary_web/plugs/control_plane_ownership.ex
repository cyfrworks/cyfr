# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.ControlPlaneOwnership do
  @moduledoc """
  Refuses every request while this member does not hold its cell slot
  (`Arca.ControlPlane.held?/0`): a lease that lapsed unrenewed means a
  successor may hold the row, and a request served here could accept a
  turn or admit an execution that the successor also admits. The check is
  a term read and an integer comparison, which is what lets it sit on
  every request. Health stays reachable so a probe can see the state
  instead of a bare 503.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["api", "health" | _]} = conn, _opts), do: conn

  def call(conn, _opts) do
    if Arca.ControlPlane.held?() do
      conn
    else
      conn
      |> put_resp_header("retry-after", "5")
      |> EmissaryWeb.ApiError.halt(
        503,
        :control_plane_lost,
        nil
      )
    end
  end
end
