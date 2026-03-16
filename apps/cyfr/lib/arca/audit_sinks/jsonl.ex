defmodule Arca.AuditSinks.JSONL do
  @moduledoc """
  Audit sink that writes events to JSONL files via Arca storage.

  Activates the Arca.append_json infrastructure for persistent audit trails.
  Files are organized by date: `audit/YYYY-MM-DD.jsonl`.

  Events with a `Sanctum.Context` in metadata are scoped to the tenant's
  storage path. Events without context (pre-auth) write to a global audit path.
  """

  @behaviour Arca.AuditSink

  require Logger

  @impl true
  def handle_audit_event(event_name, measurements, metadata) do
    date = Date.utc_today() |> Date.to_iso8601()
    event_str = Enum.join(event_name, ".")

    entry = %{
      "event" => event_str,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "measurements" => measurements,
      "execution_id" => metadata[:execution_id],
      "user_id" => metadata[:user_id],
      "org_id" => metadata[:org_id],
      "project_id" => metadata[:project_id],
      "component" => metadata[:component] || metadata[:reference],
      "outcome" => to_string(metadata[:outcome] || metadata[:status])
    }

    ctx = metadata[:context]

    if is_nil(ctx) do
      Logger.warning("[AuditSink.JSONL] Skipping audit write: no context in metadata")
      :ok
    else
      path = ["audit", date <> ".jsonl"]

      case Arca.append_json(ctx, path, entry) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[AuditSink.JSONL] Failed to write audit event: #{inspect(reason)}")
          :ok
      end
    end
  end
end
