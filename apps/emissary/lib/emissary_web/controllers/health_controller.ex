defmodule EmissaryWeb.HealthController do
  @moduledoc """
  Simple health check endpoint for load balancers and monitoring.
  """

  use EmissaryWeb, :controller

  def check(conn, _params) do
    json(conn, %{status: "ok", service: "emissary"})
  end
end
