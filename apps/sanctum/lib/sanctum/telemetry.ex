defmodule Sanctum.Telemetry do
  @moduledoc """
  Telemetry events for Sanctum.

  ## Events

  - `[:cyfr, :sanctum, :auth]` - Authentication events
    - Measurements: `%{count: 1}`
    - Metadata: `%{provider: atom(), outcome: :success | :failure}`

  ## Usage

  Attach a handler to receive events:

      :telemetry.attach(
        "my-handler",
        [:cyfr, :sanctum, :auth],
        &MyModule.handle_event/4,
        nil
      )

  Or use `Sanctum.Telemetry.attach_default_logger/0` for console logging.

  ## Example Event Flow

      # Successful GitHub auth
      Sanctum.Telemetry.auth_event(:github, :success)
      # => Emits [:cyfr, :sanctum, :auth] with %{provider: :github, outcome: :success}

      # Failed auth with reason
      Sanctum.Telemetry.auth_event(:github, :failure, %{reason: :invalid_token})
      # => Emits [:cyfr, :sanctum, :auth] with %{provider: :github, outcome: :failure, reason: :invalid_token}

  """

  @auth_event [:cyfr, :sanctum, :auth]

  @doc """
  Emit an authentication event.

  ## Parameters

  - `provider` - Authentication provider (e.g., `:github`, `:google`, `:oidc`, `:api_key`)
  - `outcome` - Result of authentication (`:success` or `:failure`)
  - `metadata` - Additional metadata map (optional)

  ## Examples

      # Successful auth
      Sanctum.Telemetry.auth_event(:github, :success)

      # Failed auth with reason
      Sanctum.Telemetry.auth_event(:github, :failure, %{reason: :invalid_credentials})

  """
  @spec auth_event(atom(), :success | :failure, map()) :: :ok
  def auth_event(provider, outcome, metadata \\ %{}) when outcome in [:success, :failure] do
    :telemetry.execute(
      @auth_event,
      %{count: 1},
      Map.merge(%{provider: provider, outcome: outcome}, metadata)
    )
  end

  @doc """
  Attach a default console logger for auth events.

  Useful for development and debugging.

  ## Example

      Sanctum.Telemetry.attach_default_logger()
      # Now auth events will be logged to console

  """
  @spec attach_default_logger() :: :ok | {:error, :already_exists}
  def attach_default_logger do
    :telemetry.attach(
      "sanctum-auth-logger",
      @auth_event,
      &log_auth_event/4,
      nil
    )
  end

  @doc """
  Detach the default console logger.
  """
  @spec detach_default_logger() :: :ok | {:error, :not_found}
  def detach_default_logger do
    :telemetry.detach("sanctum-auth-logger")
  end

  defp log_auth_event(_event, measurements, metadata, _config) do
    require Logger

    case metadata.outcome do
      :success ->
        Logger.info("[Sanctum] Auth success: provider=#{metadata.provider}")

      :failure ->
        reason = Map.get(metadata, :reason, "unknown")
        Logger.warning("[Sanctum] Auth failure: provider=#{metadata.provider} reason=#{reason}")
    end

    measurements
  end
end
