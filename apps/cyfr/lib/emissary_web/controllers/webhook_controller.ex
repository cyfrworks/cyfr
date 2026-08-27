# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.WebhookController do
  @moduledoc """
  Inbound webhook receiver.

  This controller runs after `EmissaryWeb.Plugs.WebhookRateLimit` and
  `EmissaryWeb.Plugs.VerifyWebhookSignature`, which together guarantee:

    * `conn.assigns[:webhook]` is the looked-up, enabled webhook row.
    * `conn.assigns[:raw_body]` is the verified raw request body.

  Build the invoke envelope, merge with the webhook's stored
  `input_template`, and **fire** the target component asynchronously through
  `Cyfr.Execution.run_root/5` via `Task.Supervisor.start_child/2`. The HTTP request
  returns `200 {"status":"accepted","request_id":...}` immediately — webhook
  senders only need a 2xx ack to consider delivery successful (Stripe /
  GitHub / Twilio / PayPal docs all converge on this). Component outcome is
  recorded in `RequestLog` and emitted via `[:cyfr, :emissary, :webhook,
  :invoke, :stop]` telemetry from inside the spawned task, correlated to the
  HTTP response by `request_id`.

  No controller-level timeout: the executor enforces the consented node
  timeout (`Sanctum.Limits`). A layered controller timeout would just
  produce inconsistent error reasons for the same kill.
  """

  use EmissaryWeb, :controller

  require Logger

  alias Emissary.MCP.RequestLog
  alias Sanctum.Webhook

  # Headers the component is allowed to see on the inbound POST. Anything
  # outside this list is dropped from the envelope before invocation —
  # reduces blast radius if a webhook target is later changed to a less-
  # trusted component, and keeps secrets like Authorization out of audit logs.
  @safe_header_allowlist ~w(
    content-type
    user-agent
    x-github-event
    x-github-delivery
    x-hub-signature-256
    x-gitlab-event
    stripe-signature
    x-twilio-signature
    x-request-id
  )

  def invoke(conn, _params) do
    webhook = conn.assigns[:webhook]

    cond do
      is_nil(webhook) ->
        # Defensive — verify plug should have halted before us.
        EmissaryWeb.ApiError.send(conn, 500, :internal_error, "Internal error")

      not Sanctum.Tenancy.channel_active?(webhook.athanor_id, webhook.created_by) ->
        # The athanor is archived or the creator was denied on this server —
        # the stored row must not remain a standing execution channel. Same
        # response shape as a disabled webhook so existence is not leaked.
        Logger.warning(
          "[WebhookInvoke] athanor #{webhook.athanor_id} or creator " <>
            "#{inspect(webhook.created_by)} no longer active — refusing slug=#{webhook.slug}"
        )

        EmissaryWeb.ApiError.send(conn, 404, :not_found, "Not found")

      true ->
        invoke_active(conn, webhook, conn.assigns[:raw_body])
    end
  end

  defp invoke_active(conn, webhook, raw_body) do
    request_id = Emissary.UUID7.request_id()
    # Same key on the log lines as on the RequestLog row this run files.
    Cyfr.LoggerContext.set_request_id(request_id)
    ctx = build_webhook_context(webhook, request_id)

    with :ok <- Sanctum.Context.tenant_ok(ctx),
         {:ok, template} <- Webhook.decode_input_template(webhook.input_template) do
      input = build_input(template, conn, raw_body, webhook, request_id)
      run_logged_invoke(conn, ctx, request_id, webhook, input)
    else
      {:error, :missing_tenant} ->
        # Webhook row with no resolved athanor — should never happen for a
        # well-formed row, but fail closed to preserve isolation.
        Logger.error(
          "[WebhookInvoke] webhook slug=#{webhook.slug} has no resolved athanor — rejecting"
        )

        EmissaryWeb.ApiError.send(conn, 500, :internal_error, "Internal error")

      {:error, reason} ->
        Logger.error(
          "[WebhookInvoke] stored input_template invalid slug=#{webhook.slug} reason=#{inspect(reason)}"
        )

        EmissaryWeb.ApiError.send(conn, 500, :internal_error, "Internal error")
    end
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp build_webhook_context(webhook, request_id) do
    # namespace is identity-only (not path-bearing); resolve the owner's handle
    # for attribution, nil if the webhook is orphaned. Storage is scoped by the
    # webhook's athanor.
    namespace =
      case webhook.created_by do
        user_id when is_binary(user_id) and user_id != "" -> Sanctum.Namespace.lookup(user_id)
        _ -> nil
      end

    Sanctum.Context.build(
      user_id: "webhook:#{webhook.slug}",
      namespace: namespace,
      permissions: [:execute],
      athanor_id: webhook.athanor_id,
      auth_method: :webhook,
      # authenticated gates tool dispatch; anonymous gates credentials.
      # A webhook context is not anonymous: the hook is operator-created
      # and consented (profile_id is required at create), so its bound
      # executions may read their vault material.
      authenticated: true,
      anonymous: false,
      request_id: request_id
    )
  end

  defp build_input(template, conn, raw_body, webhook, request_id) do
    envelope = %{
      "headers" => safe_headers(conn, webhook.signature_header),
      "body" => raw_body,
      "body_json" => parsed_body_json(conn),
      "metadata" => %{
        "webhook_slug" => webhook.slug,
        "webhook_name" => webhook.name,
        "received_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "request_id" => request_id
      }
    }

    Map.put(template, "_webhook", envelope)
  end

  defp parsed_body_json(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: nil
  defp parsed_body_json(%Plug.Conn{body_params: %{} = params}), do: params
  defp parsed_body_json(_), do: nil

  # Every known signature-carrying header is dropped, not just the one this
  # webhook verifies with: a GitHub-configured hook has no business handing
  # the target component a Stripe or Twilio signature that happened to ride
  # along on the request.
  @signature_headers ~w(x-hub-signature-256 stripe-signature x-twilio-signature)

  defp safe_headers(conn, signature_header) do
    drop = [String.downcase(signature_header || Sanctum.Webhook.default_signature_header())]
    drop = drop ++ @signature_headers

    conn.req_headers
    |> Enum.filter(fn {name, _} -> String.downcase(name) in @safe_header_allowlist end)
    |> Enum.reject(fn {name, _} -> String.downcase(name) in drop end)
    |> Map.new(fn {name, value} -> {String.downcase(name), value} end)
  end

  defp run_logged_invoke(conn, ctx, request_id, webhook, input) do
    log_input = %{
      webhook_slug: webhook.slug,
      webhook_name: webhook.name,
      target_ref: webhook.target_ref
    }

    telemetry_meta = %{
      request_id: request_id,
      webhook_slug: webhook.slug,
      webhook_name: webhook.name,
      reference: webhook.target_ref,
      athanor_id: ctx.athanor_id,
      user_id: ctx.user_id
    }

    RequestLog.safe_log_started(ctx, request_id, %{
      tool: "webhook",
      action: "invoke",
      method: "POST /hooks/:slug",
      input: log_input
    })

    start_time = System.monotonic_time()

    :telemetry.execute(
      [:cyfr, :emissary, :webhook, :invoke, :start],
      %{system_time: System.system_time()},
      telemetry_meta
    )

    # Capture Logger metadata before spawn — `Task.Supervisor.start_child` does
    # not inherit it. Same idiom as `EmissaryWeb.Plugs.Authenticate`.
    logger_metadata = Cyfr.LoggerContext.capture()

    # The release starts :cyfr (binding this endpoint) before :opus brings
    # up the execution machinery — refuse the request cleanly in that
    # window instead of accepting work that noproc-crashes in the task.
    spawn_result =
      if Cyfr.Execution.available?() do
        Task.Supervisor.start_child(Emissary.TaskSupervisor, fn ->
          Cyfr.LoggerContext.restore(logger_metadata)
          run_in_task(ctx, request_id, webhook, input, telemetry_meta, start_time)
        end)
      else
        {:error, :engine_starting}
      end

    case spawn_result do
      {:ok, _pid} ->
        json(conn, %{status: "accepted", request_id: request_id})

      {:error, reason} ->
        Logger.error("[WebhookInvoke] task spawn failed slug=#{webhook.slug}: #{inspect(reason)}")

        duration_ms = duration_ms(start_time)

        RequestLog.safe_log_failed(ctx, request_id, %{
          error: "task_spawn_failed: #{inspect(Sanctum.Sanitizer.sanitize(reason))}",
          duration_ms: duration_ms,
          routed_to: "opus"
        })

        :telemetry.execute(
          [:cyfr, :emissary, :webhook, :invoke, :stop],
          %{duration_ms: duration_ms},
          telemetry_meta
          |> Map.put(:status, :error)
          |> Map.put(:error, "task_spawn_failed: #{inspect(Sanctum.Sanitizer.sanitize(reason))}")
        )

        EmissaryWeb.ApiError.send(conn, 503, :service_unavailable, "Service unavailable — try again shortly")
    end
  end

  # Task body. Wrapped in try/rescue so the audit trail (`RequestLog` row +
  # `:invoke, :stop` telemetry) closes whether `Cyfr.Execution.run_root/5` returns
  # `{:ok, _}`, `{:error, _}`, or raises. The supervisor would log a crash
  # otherwise, but the structured audit row would dangle in `pending`.
  defp run_in_task(ctx, request_id, webhook, input, telemetry_meta, start_time) do
    try do
      # A webhook fires under its bound profile's consent — the binding is
      # enforced at create/update and by the NOT NULL column.
      run_result =
        Cyfr.Execution.run_root(ctx, webhook.profile_id, webhook.target_ref, input,
          class: :background
        )

      case run_result do
        {:ok, result} ->
          duration_ms = duration_ms(start_time)

          RequestLog.safe_log_completed(ctx, request_id, %{
            output: result.output,
            duration_ms: duration_ms,
            routed_to: "opus"
          })

          :telemetry.execute(
            [:cyfr, :emissary, :webhook, :invoke, :stop],
            %{duration_ms: duration_ms},
            Map.put(telemetry_meta, :status, :ok)
          )

        {:error, reason} ->
          duration_ms = duration_ms(start_time)
          Logger.warning("[WebhookInvoke] error slug=#{webhook.slug}: #{inspect(reason)}")

          RequestLog.safe_log_failed(ctx, request_id, %{
            error:
              if(is_binary(reason),
                do: reason,
                else: inspect(Sanctum.Sanitizer.sanitize(reason))
              ),
            duration_ms: duration_ms,
            routed_to: "opus"
          })

          :telemetry.execute(
            [:cyfr, :emissary, :webhook, :invoke, :stop],
            %{duration_ms: duration_ms},
            telemetry_meta |> Map.put(:status, :error) |> Map.put(:error, inspect(reason))
          )
      end
    rescue
      e ->
        duration_ms = duration_ms(start_time)
        formatted = Exception.format(:error, e, __STACKTRACE__)
        Logger.error("[WebhookInvoke] crashed slug=#{webhook.slug}\n#{formatted}")

        RequestLog.safe_log_failed(ctx, request_id, %{
          error: Exception.message(e),
          duration_ms: duration_ms,
          routed_to: "opus"
        })

        :telemetry.execute(
          [:cyfr, :emissary, :webhook, :invoke, :stop],
          %{duration_ms: duration_ms},
          telemetry_meta
          |> Map.put(:status, :error)
          |> Map.put(:error, Exception.message(e))
        )
    end
  end

  defp duration_ms(start_time) do
    System.monotonic_time()
    |> Kernel.-(start_time)
    |> System.convert_time_unit(:native, :millisecond)
  end
end
