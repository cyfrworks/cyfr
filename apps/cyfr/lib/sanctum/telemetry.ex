# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Telemetry do
  @moduledoc """
  Telemetry events for Sanctum.

  ## Events

  - `[:cyfr, :sanctum, :auth]` - Authentication events
    - Measurements: `%{count: 1}`
    - Metadata: `%{provider: atom(), outcome: :success | :failure}`

  - `[:cyfr, :sanctum, :policy]` - Policy change events
    - Measurements: `%{count: 1}`
    - Metadata: `%{action: atom(), component_ref: String.t()}`

  - `[:cyfr, :sanctum, :policy, :resolve_error]` - Policy resolution failures
    - Measurements: `%{count: 1}`
    - Metadata: `%{class: atom(), component_ref: String.t()}`

  - `[:cyfr, :sanctum, :platform_context]` - Platform-scope context built
    - Measurements: `%{count: 1}`
    - Metadata: `%{user_id, auth_method, namespace, sanctioned: boolean(), caller}`

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
  @policy_event [:cyfr, :sanctum, :policy]
  @policy_resolve_error_event [:cyfr, :sanctum, :policy, :resolve_error]
  @platform_context_event [:cyfr, :sanctum, :platform_context]

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
  Emit a policy change event.

  ## Parameters

  - `action` - What changed (`:put`, `:update_field`, `:delete`)
  - `component_ref` - The component reference
  - `metadata` - Additional metadata map (optional)
  """
  @spec policy_event(atom(), String.t(), map()) :: :ok
  def policy_event(action, component_ref, metadata \\ %{}) do
    :telemetry.execute(
      @policy_event,
      %{count: 1},
      Map.merge(%{action: action, component_ref: component_ref}, metadata)
    )
  end

  @doc """
  Emit a policy-resolution-error event.

  - `class` - the failure class. `:invalid_ref` means an un-normalizable
    `component_ref` (missing type prefix / version) — a caller bug that now
    fails closed instead of silently substituting a type-default policy.
  - `component_ref` - the offending reference
  - `metadata` - additional metadata map (optional)

  Emits `[:cyfr, :sanctum, :policy, :resolve_error]` so a previously-masked
  caller bug is observable.
  """
  @spec policy_resolve_error(atom(), String.t(), map()) :: :ok
  def policy_resolve_error(class, component_ref, metadata \\ %{}) do
    :telemetry.execute(
      @policy_resolve_error_event,
      %{count: 1},
      Map.merge(%{class: class, component_ref: component_ref}, metadata)
    )
  end

  @doc """
  Emit a platform-context construction event.

  Every `scope: :platform` context (system tasks / cron / bootstrap) is
  audited here — there was previously no record of who constructs the
  tenant-bypassing platform scope. `metadata.sanctioned` is `true` when built
  through the single sanctioned path (`Sanctum.Context.internal/1` /
  `Sanctum.system_context/0`), `false` for a direct `Context.build`.

  Emits `[:cyfr, :sanctum, :platform_context]`.
  """
  @spec platform_context_event(map()) :: :ok
  def platform_context_event(metadata) when is_map(metadata) do
    :telemetry.execute(@platform_context_event, %{count: 1}, metadata)
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
