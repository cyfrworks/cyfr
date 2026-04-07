defmodule Prism.AgentScheduler do
  @moduledoc """
  Thin wrapper for scheduling agent formula runs via Opus.CronScheduler.

  Composes the formula input (catalyst_ref, model, task, system prompt) and
  creates a cron schedule targeting `formula:local.aqua`.
  """

  alias Sanctum.Context

  @agent_ref "formula:local.aqua"

  @doc """
  Schedule a recurring agent task.

  Options:
    - `:catalyst_ref` — LLM catalyst reference (e.g., "catalyst:moonmoon69.claude:1.0.0")
    - `:model` — model identifier (e.g., "claude-sonnet-4-5-20250514")
  """
  def schedule_task(%Context{} = ctx, name, cron_expr, task, opts \\ []) do
    catalyst_ref = Keyword.fetch!(opts, :catalyst_ref)
    model = Keyword.fetch!(opts, :model)

    input = build_scheduled_input(ctx, task, catalyst_ref, model)

    Emissary.MCP.ToolRegistry.call("schedule", ctx, %{
      "action" => "create",
      "name" => name,
      "cron_expression" => cron_expr,
      "reference" => @agent_ref,
      "input" => input,
      "metadata" => %{
        "source" => "agent_scheduler",
        "task_summary" => String.slice(task, 0..100)
      }
    })
  end

  @doc """
  Build the formula input map for a scheduled agent run.
  """
  def build_scheduled_input(%Context{} = ctx, task, catalyst_ref, model) do
    system_prompt = build_headless_system_prompt(ctx)

    sub_agents =
      Prism.AgentConfig.sub_agent_definitions(ctx, "aqua", catalyst_ref, model)

    %{
      "catalyst_ref" => catalyst_ref,
      "model" => model,
      "task" => task,
      "system" => system_prompt,
      "sub_agents" => sub_agents
    }
  end

  defp build_headless_system_prompt(%Context{} = ctx) do
    base = PrismWeb.AgentLive.build_system_prompt(ctx)
    base <> "\n\nYou are running as a scheduled task (headless). Be concise and action-oriented. Store results using the storage tool for later retrieval."
  end
end
