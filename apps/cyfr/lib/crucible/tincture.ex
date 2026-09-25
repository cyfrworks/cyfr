# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Tincture do
  @moduledoc """
  A tincture invoking one of its dependencies (`Crucible.invoke_tincture/3`).

  The route is the profile the run roots at. `:public` is the tincture's
  public address, whoever calls: the athanor its URL names, read through
  `Sanctum.TinctureAccess.public_context/1`, and the tincture's currently
  published public profile there. The address confers no authority — the
  active public profile admits — the caller's own athanor is not
  consulted, and the run is the public identity's. `:protected` is the
  caller's own athanor and the tincture's owner profile, for a caller
  Sanctum's private-access policy admits. The tincture and its profile are
  read again on every call — a surface's cached tincture is never
  authority — and an absent tincture answers as an inaccessible one does,
  `not_found`. The profile the route selects roots the run and its edge to
  `reference` decides what the dependency may reach
  (`Crucible.run_root_edge/5`).

  The arguments are the gate's cast of the declared operation's
  (`Crucible.Providers.Tincture`); the gate is their one validator. A
  context that has entered a guest refuses; the caller's address
  (`ctx.client_ip`) is what a public profile's per-address rate bucket is
  charged to. Every answer is plain data or a `%Prima.Refusal{}`: the
  surface renders it, the gate logs the call and correlates it by its own
  request id, and this module emits the invocation's telemetry.
  """

  require Logger

  alias Sanctum.Context

  @type route :: :public | :protected

  @type result :: %{
          status: term(),
          output: term(),
          execution_id: String.t() | nil,
          duration_ms: non_neg_integer() | nil
        }

  @routes [:public, :protected]
  @start [:cyfr, :crucible, :tincture, :invoke, :start]
  @stop [:cyfr, :crucible, :tincture, :invoke, :stop]

  # A route whose profile does not exist, no longer stands, or was never
  # granted: the tincture is not consented to run under it.
  @unconsented [:no_profile, :no_public_profile]

  @doc """
  Invoke `args["reference"]` with `args["input"]` on behalf of the tincture
  `args["publisher"]`/`args["tincture_name"]`, rooted at the profile
  `route` selects. The arguments are the gate's cast of the declared
  operation's; `:public` also takes `args["athanor"]`, the tincture's
  public address.
  """
  @spec invoke(Context.t(), map(), route()) :: {:ok, result()} | {:error, Prima.Refusal.t()}
  def invoke(%Context{plane: :guest}, _args, route) when route in @routes,
    do: {:error, refusal({:guest_plane_call, "tincture"})}

  def invoke(%Context{} = ctx, args, route) when route in @routes do
    %{
      "publisher" => publisher,
      "tincture_name" => name,
      "reference" => reference,
      "input" => input
    } = args

    case reread(ctx, route, args, publisher, name) do
      {:ok, tincture, source_ctx} -> run(ctx, source_ctx, tincture, reference, input, route)
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  # The public route reads under the address's public context, never the
  # caller's; the protected route under the caller's own. A refusal of
  # either reads as absence.
  defp reread(_ctx, :public, %{"athanor" => address}, publisher, name) do
    with {:ok, public_ctx} <- Sanctum.TinctureAccess.public_context(address),
         {:ok, tincture} <- found(Sanctum.TinctureAccess.get_public(public_ctx, publisher, name)) do
      {:ok, tincture, public_ctx}
    end
  end

  defp reread(ctx, :protected, _args, publisher, name) do
    with {:ok, tincture} <- found(Sanctum.TinctureAccess.get_private(ctx, publisher, name)) do
      {:ok, tincture, ctx}
    end
  end

  defp found({:ok, tincture}), do: {:ok, tincture}
  defp found({:error, _refused}), do: {:error, :not_found}

  # `ctx` is the caller's, as the gate admitted it; `source_ctx` the one
  # the tincture was read under, which the run's identity derives from.
  defp run(ctx, source_ctx, tincture, reference, input, route) do
    tincture_ref = Prima.ComponentRef.build("tincture", tincture.publisher, tincture.name)

    # The run's context is the tincture's, correlated by the request the
    # gate filed this call under.
    run_ctx = %{
      Sanctum.build_tincture_context(source_ctx, tincture)
      | request_id: ctx.request_id
    }

    if is_binary(run_ctx.request_id), do: Prima.LoggerContext.set_request_id(run_ctx.request_id)
    Prima.LoggerContext.set_from_context(run_ctx)

    meta = %{
      request_id: run_ctx.request_id,
      tincture_ref: tincture_ref,
      reference: reference,
      athanor_id: run_ctx.athanor_id,
      user_id: run_ctx.user_id
    }

    :telemetry.execute(@start, %{system_time: System.system_time()}, meta)
    started = System.monotonic_time()

    # The endpoints start before the execution machinery; a call in that
    # window is refused, never crashed.
    outcome =
      if Crucible.available?() do
        Crucible.run_root_edge(run_ctx, tincture_ref, reference, input,
          route: route,
          client_ip: ctx.client_ip
        )
      else
        {:error, :engine_starting}
      end

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    finish(outcome, meta, duration_ms)
  end

  defp finish({:ok, result}, meta, duration_ms) do
    :telemetry.execute(@stop, %{duration_ms: duration_ms}, Map.put(meta, :status, :ok))

    {:ok,
     %{
       status: result.status,
       output: result.output,
       execution_id: result.metadata.execution_id,
       duration_ms: result.metadata.duration_ms
     }}
  end

  defp finish({:error, reason}, meta, duration_ms) do
    # Sanitized before `inspect/1`, which would erase the field boundaries
    # the redaction reads.
    unless expected?(reason),
      do:
        Logger.warning(
          "[Crucible.Tincture] refused: #{inspect(Prima.Sanitizer.sanitize(reason))}"
        )

    refusal = refusal(reason)

    :telemetry.execute(
      @stop,
      %{duration_ms: duration_ms},
      Map.merge(meta, %{status: :error, error: refusal})
    )

    {:error, refusal}
  end

  # The tincture's own consent refusal keeps the producer's reason; every
  # other reason is the closed table's.
  defp refusal(reason) when reason in @unconsented, do: unconsented(reason)
  defp refusal({:profile_unavailable, _status} = reason), do: unconsented(reason)
  defp refusal(reason), do: Grimoire.Error.classify(reason)

  defp unconsented(reason), do: %{Prima.Refusal.classify(:consent_required) | reason: reason}

  # What a caller is told as it is: a profile to grant, an engine still
  # starting. Anything else is logged for the operator too.
  defp expected?(reason) when reason in [:engine_starting | @unconsented], do: true
  defp expected?({:profile_unavailable, _status}), do: true
  defp expected?(_reason), do: false
end
