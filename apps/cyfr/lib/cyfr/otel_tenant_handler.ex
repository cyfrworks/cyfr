# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.OtelTenantHandler do
  @moduledoc """
  Telemetry handler that bridges tenant metadata to OpenTelemetry span attributes.

  Attaches to Phoenix telemetry events and adds `tenant.athanor_id` and
  `tenant.user_id` attributes to the current span. `Cyfr.Application`
  attaches it when tracing is enabled.
  """

  require Logger

  @handler_id "cyfr-otel-tenant"

  # Use :stop events with the post-pipeline connection and resolved context.
  # Endpoint :stop also covers requests halted during authentication.
  @events [
    [:phoenix, :endpoint, :stop],
    [:phoenix, :router_dispatch, :stop]
  ]

  @doc "Attach the telemetry handler, replacing an earlier attach of it."
  @spec attach() :: :ok
  def attach do
    # Handlers are global to the node. Attaching over an existing id
    # answers `{:error, :already_exists}` and changes nothing, so a second
    # boot (a release restart, a restart of :cyfr) would keep the first
    # attach and log that it had attached. Detach first, and say so when
    # the attach itself fails.
    :telemetry.detach(@handler_id)

    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{}) do
      :ok ->
        Logger.debug("[OtelTenantHandler] Attached to #{length(@events)} telemetry events")

      {:error, reason} ->
        Logger.error(
          "[OtelTenantHandler] attach failed: #{inspect(reason)} — " <>
            "spans will carry no tenant attribution"
        )
    end
  end

  @doc false
  def handle_event(_event, _measurements, metadata, _config) do
    attrs = attributes_from(metadata[:conn])

    if attrs != [] do
      OpenTelemetry.Span.set_attributes(OpenTelemetry.Tracer.current_span_ctx(), attrs)
    end

    :ok
  rescue
    # Span attribution must never take a request down, but a failure here
    # means tenant tracing is silently absent — visible at default levels,
    # not buried at :debug.
    e ->
      Logger.warning(
        "[OtelTenantHandler] handle_event failed: #{Prima.LogFilter.exception_message(e)}"
      )

      :ok
  end

  @doc """
  The tenant attributes a request's span carries: the athanor and the
  person of the conn's `Sanctum.Context`, each only when set, and none
  for a conn without one.
  """
  def attributes_from(%Plug.Conn{assigns: assigns}) do
    case assigns[:context] do
      # Only a real Context carries tenant fields; a stray non-struct
      # assign yields nothing rather than KeyError-ing into the rescue.
      %Sanctum.Context{} = ctx ->
        [
          {"tenant.athanor_id", ctx.athanor_id},
          {"tenant.user_id", ctx.user_id}
        ]
        |> Enum.reject(fn {_, v} -> is_nil(v) end)

      _ ->
        []
    end
  end

  def attributes_from(_), do: []
end
