# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.OtelTenantHandler do
  @moduledoc """
  Telemetry handler that bridges tenant metadata to OpenTelemetry span attributes.

  Attaches to Phoenix/Bandit telemetry events and adds `tenant.athanor_id`
  and `tenant.user_id` attributes to the current OTEL span.

  Only activates when OpenTelemetry is loaded. Safe to call when OTEL is absent.
  """

  require Logger

  @handler_id "cyfr-otel-tenant"

  # The :stop events, deliberately: Phoenix emits router_dispatch :start
  # BEFORE the pipeline runs (deps/phoenix router.ex — the conn in the
  # :start metadata predates every plug), so `assigns[:context]` — set by
  # EmissaryWeb.Plugs.Authenticate inside the pipeline — was always nil
  # there and no tenant attribute was ever written. The :stop metadata
  # carries the post-pipeline conn; :endpoint :stop fires via
  # register_before_send, so a request halted by auth still lands here.
  @events [
    [:phoenix, :endpoint, :stop],
    [:phoenix, :router_dispatch, :stop]
  ]

  @doc """
  Attach the telemetry handler. No-op if OpenTelemetry is not loaded.
  """
  def attach do
    if otel_available?() do
      :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{})
      Logger.debug("[OtelTenantHandler] Attached to #{length(@events)} telemetry events")
    else
      Logger.debug("[OtelTenantHandler] OpenTelemetry not loaded, skipping attach")
    end
  end

  @doc false
  def handle_event(_event, _measurements, metadata, _config) do
    if otel_available?() do
      attrs = attributes_from(metadata[:conn])

      if attrs != [] do
        span_ctx = apply(OpenTelemetry.Tracer, :current_span_ctx, [])
        apply(OpenTelemetry.Span, :set_attributes, [span_ctx, attrs])
      end
    end

    :ok
  rescue
    # Span attribution must never take a request down, but a failure here
    # means tenant tracing is silently absent — visible at default levels,
    # not buried at :debug.
    e ->
      Logger.warning("[OtelTenantHandler] handle_event failed: #{Exception.message(e)}")
      :ok
  end

  @doc false
  # The pure half, split out so a test can assert what a conn yields
  # without a live span.
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

  defp otel_available? do
    Code.ensure_loaded?(OpenTelemetry) and Code.ensure_loaded?(OpenTelemetry.Tracer)
  end
end
