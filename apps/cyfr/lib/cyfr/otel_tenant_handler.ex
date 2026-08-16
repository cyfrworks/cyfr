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

  @events [
    [:phoenix, :endpoint, :start],
    [:phoenix, :router_dispatch, :start]
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
      conn = metadata[:conn]

      if conn && is_map(conn.assigns) do
        ctx = conn.assigns[:context]

        # Only a real Context carries tenant fields; guard up front so a stray
        # non-struct assign fails fast/clearly instead of KeyError-ing into the
        # rescue below.
        if is_struct(ctx, Sanctum.Context) do
          set_span_attributes(ctx)
        end
      end
    end
  rescue
    e ->
      Logger.debug("[OtelTenantHandler] handle_event failed: #{Exception.message(e)}")
      :ok
  end

  defp set_span_attributes(ctx) do
    attrs =
      [
        {"tenant.athanor_id", ctx.athanor_id},
        {"tenant.user_id", ctx.user_id}
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    if attrs != [] do
      span_ctx = apply(OpenTelemetry.Tracer, :current_span_ctx, [])
      apply(OpenTelemetry.Span, :set_attributes, [span_ctx, attrs])
    end
  end

  defp otel_available? do
    Code.ensure_loaded?(OpenTelemetry) and Code.ensure_loaded?(OpenTelemetry.Tracer)
  end
end
