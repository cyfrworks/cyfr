# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Tincture.Invoke do
  @moduledoc """
  The one tincture-invoke ingress implementation.

  Two surfaces reach it — `POST /t/.../invoke` (EmissaryWeb.TinctureController)
  and the console shell's iframe bridge (PrismWeb.ShellLive) — and both are
  classified execution ingresses. They used to carry separate copies that
  drifted four ways: the console emitted no telemetry (so its invocations
  were invisible to the activity feed and the topbar indicator), passed no
  client identity, skipped the engine-readiness gate, and the controller's
  audit row skipped the sanitizer the console applied. One implementation
  owns validation, the context build, the request log, the telemetry pair,
  the readiness gate and the sanitize-then-inspect audit discipline; the
  surfaces keep only their own rendering and their own rate budgets.

  Returns `{:ok, result}` or `{:error, code, message}` where `code` is the
  stable slug both surfaces render their own way (`ApiError` with a status,
  or the iframe response envelope).
  """

  require Logger

  alias Emissary.MCP.RequestLog

  @type result :: %{
          status: term(),
          output: term(),
          execution_id: term(),
          duration_ms: term()
        }

  @doc """
  Validate and run a tincture invocation.

  `opts`:

    * `:route` — `:public | :protected`; which profile roots the run.
    * `:method` — the request-log method string naming the surface.
    * `:client_ip` — the caller's resolved IP, when the surface has one
      (the LiveView socket does not; `nil` is honest there).
  """
  @spec run(Sanctum.Context.t(), map(), term(), term(), keyword()) ::
          {:ok, result()} | {:error, atom(), String.t()}
  def run(auth_ctx, tincture, reference, input, opts) do
    cond do
      !is_binary(reference) or reference == "" ->
        {:error, :invalid_params, "missing reference"}

      !is_map(input) ->
        {:error, :invalid_params, "input must be an object"}

      true ->
        do_run(auth_ctx, tincture, reference, input, opts)
    end
  end

  defp do_run(auth_ctx, tincture, reference, input, opts) do
    route = Keyword.fetch!(opts, :route)
    method = Keyword.fetch!(opts, :method)
    tincture_ref = "tincture:#{tincture.publisher}.#{tincture.name}"

    ctx = %{Sanctum.build_tincture_context(auth_ctx, tincture) | request_id: request_id()}

    telemetry_meta = %{
      request_id: ctx.request_id,
      tincture_ref: tincture_ref,
      reference: reference,
      athanor_id: ctx.athanor_id,
      user_id: ctx.user_id
    }

    RequestLog.safe_log_started(ctx, ctx.request_id, %{
      tool: "tincture",
      action: "invoke",
      method: method,
      input: %{
        publisher: tincture.publisher,
        tincture_name: tincture.name,
        reference: reference,
        input: input
      }
    })

    start_time = System.monotonic_time()

    :telemetry.execute(
      [:cyfr, :emissary, :tincture, :invoke, :start],
      %{system_time: System.system_time()},
      telemetry_meta
    )

    # The tincture's profile owns the authority, selected by the route.
    # The release starts :cyfr (the endpoints) before :opus brings up the
    # execution machinery; a request in that window is refused cleanly
    # rather than noproc-crashing mid-flight.
    run_result =
      if Cyfr.Execution.available?() do
        Cyfr.Execution.run_root_edge(ctx, tincture_ref, reference, input,
          route: route,
          client_ip: Keyword.get(opts, :client_ip)
        )
      else
        {:error, :engine_starting}
      end

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

    finish(run_result, ctx, telemetry_meta, duration_ms, route)
  end

  defp finish({:ok, result}, ctx, telemetry_meta, duration_ms, _route) do
    RequestLog.safe_log_completed(ctx, ctx.request_id, %{
      output: result.output,
      duration_ms: duration_ms,
      routed_to: "opus"
    })

    emit_stop(telemetry_meta, duration_ms, :ok, nil)

    {:ok,
     %{
       status: result.status,
       output: result.output,
       execution_id: result.metadata.execution_id,
       duration_ms: result.metadata.duration_ms
     }}
  end

  defp finish({:error, no_profile}, ctx, telemetry_meta, duration_ms, route)
       when no_profile in [:no_profile, :no_public_profile] do
    log_failed(ctx, to_string(no_profile), duration_ms)
    emit_stop(telemetry_meta, duration_ms, :error, to_string(no_profile))

    {:error, :consent_required,
     "this tincture has no #{route_name(route)} profile — grant it first"}
  end

  defp finish({:error, :engine_starting}, ctx, telemetry_meta, duration_ms, _route) do
    log_failed(ctx, "engine_starting", duration_ms)
    emit_stop(telemetry_meta, duration_ms, :error, "engine_starting")
    {:error, :service_unavailable, "Execution engine is starting — retry shortly"}
  end

  defp finish({:error, reason}, ctx, telemetry_meta, duration_ms, _route) do
    Logger.warning("[Tincture.Invoke] error: #{inspect(reason)}")

    # Sanitize BEFORE inspect: once flattened to a string, the sanitizer's
    # sensitive-key redaction can no longer see the map it protects.
    log_failed(
      ctx,
      if(is_binary(reason), do: reason, else: inspect(Sanctum.Sanitizer.sanitize(reason))),
      duration_ms
    )

    emit_stop(telemetry_meta, duration_ms, :error, "execution_failed")

    # Chain errors are crafted strings and pass through; anything else is
    # an internal term the caller must not see.
    message = if is_binary(reason), do: reason, else: "Execution failed"
    {:error, :execution_failed, message}
  end

  defp log_failed(ctx, error, duration_ms) do
    RequestLog.safe_log_failed(ctx, ctx.request_id, %{
      error: error,
      duration_ms: duration_ms,
      routed_to: "opus"
    })
  end

  defp emit_stop(telemetry_meta, duration_ms, status, error) do
    meta = Map.put(telemetry_meta, :status, status)
    meta = if error, do: Map.put(meta, :error, error), else: meta

    :telemetry.execute(
      [:cyfr, :emissary, :tincture, :invoke, :stop],
      %{duration_ms: duration_ms},
      meta
    )
  end

  defp request_id, do: Emissary.UUID7.request_id()

  defp route_name(:public), do: "public"
  defp route_name(_), do: "protected"
end
