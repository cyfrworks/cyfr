defmodule EmissaryWeb.HealthController do
  @moduledoc """
  Health check endpoints for load balancers and monitoring.

  - `/api/health` — liveness probe (always 200)
  - `/api/health/ready` — readiness probe (checks DB + cache)
  """

  use EmissaryWeb, :controller

  def check(conn, _params) do
    json(conn, %{status: "ok", service: "emissary"})
  end

  def ready(conn, _params) do
    checks = %{
      database: check_database(),
      cache: check_cache()
    }

    checks =
      if Sanctum.Edition.arx?() do
        Map.merge(checks, %{
          pubsub: check_pubsub(),
          tool_registry: check_process(Emissary.MCP.ToolRegistry),
          resource_registry: check_process(Emissary.MCP.ResourceRegistry),
          sse_buffer: check_process(Emissary.MCP.SSEBuffer)
        })
      else
        checks
      end

    all_ok = Enum.all?(checks, fn {_k, v} -> v == :ok end)

    status_code = if all_ok, do: 200, else: 503

    conn
    |> put_status(status_code)
    |> json(%{
      status: if(all_ok, do: "ready", else: "not_ready"),
      checks:
        Map.new(checks, fn {k, v} ->
          {k, if(v == :ok, do: "ok", else: inspect(v))}
        end)
    })
  end

  defp check_database do
    case Arca.Repo.query("SELECT 1") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp check_cache do
    if :ets.whereis(Arca.Cache.table_name()) != :undefined do
      :ok
    else
      {:error, :ets_missing}
    end
  end

  defp check_pubsub do
    topic = "health_check:#{System.unique_integer([:positive])}"

    Phoenix.PubSub.subscribe(Emissary.PubSub, topic)
    Phoenix.PubSub.broadcast(Emissary.PubSub, topic, :ping)

    receive do
      :ping -> :ok
    after
      1_000 -> {:error, :pubsub_timeout}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp check_process(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: :ok, else: {:error, :not_alive}

      nil ->
        {:error, :not_registered}
    end
  end
end
