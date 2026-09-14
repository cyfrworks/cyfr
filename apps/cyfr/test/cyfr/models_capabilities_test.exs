# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ModelsCapabilitiesTest do
  @moduledoc """
  A model's capabilities are its catalyst's `describe` of that model: the
  window and output ceiling come from the answer, a model the catalyst
  does not know and a describe that fails are errors, and only a reading
  that succeeded is cached, under the key it ran with.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Models

  @ref "catalyst:local.claude:1.3.0"

  setup do
    Arca.Cache.init()
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp envelope(data), do: %{result: %{"status" => 200, "data" => data}}
  defp refusal(error), do: %{result: %{"status" => 404, "error" => error}}

  defp counted(answer) do
    counter = :counters.new(1, [])

    run = fn %{"operation" => "describe", "params" => params} ->
      :counters.add(counter, 1, 1)
      answer.(params)
    end

    {run, fn -> :counters.get(counter, 1) end}
  end

  test "the described model's window and ceiling are its capabilities, cached under the key",
       %{ctx: ctx} do
    {run, runs} =
      counted(fn %{"model" => "claude-x"} ->
        {:ok,
         envelope(%{
           "provider_tools" => ["web_search"],
           "media_types" => ["image/png"],
           "streaming" => true,
           "defaults" => %{"max_tokens" => 8192},
           "model" => "claude-x",
           "context_window" => 500_000,
           "max_output_tokens" => 32_000
         })}
      end)

    assert {:ok,
            %{
              context_window: 500_000,
              max_output_tokens: 32_000,
              provider_tools: ["web_search"],
              media_types: ["image/png"],
              streaming: true,
              default_max_tokens: 8192
            }} = Models.capabilities(ctx, @ref, "claude-x", "sha256:a", run: run)

    assert {:ok, %{context_window: 500_000}} =
             Models.capabilities(ctx, @ref, "claude-x", "sha256:a", run: run)

    assert runs.() == 1

    assert {:ok, %{context_window: 500_000}} =
             Models.capabilities(ctx, @ref, "claude-x", "sha256:other", run: run)

    assert runs.() == 2
  end

  test "an unknown model, a refusal, a missing window and a failed run are errors, never cached",
       %{ctx: ctx} do
    unknown = fn _ ->
      {:ok, refusal(%{"type" => "unknown_model", "message" => "not a model"})}
    end

    assert {:error, {:unknown_model, "gpt-x"}} =
             Models.capabilities(ctx, @ref, "gpt-x", "sha256:u", run: unknown)

    {denied, runs} =
      counted(fn _ ->
        {:ok, refusal(%{"type" => "secret_denied", "message" => "no key"})}
      end)

    assert {:error, {:model_refused, %{"type" => "secret_denied"}}} =
             Models.capabilities(ctx, @ref, "m", "sha256:d", run: denied)

    assert {:error, {:model_refused, _}} =
             Models.capabilities(ctx, @ref, "m", "sha256:d", run: denied)

    assert runs.() == 2

    windowless = fn _ -> {:ok, envelope(%{"model" => "m", "streaming" => true})} end

    assert {:error, {:no_context_window, "m"}} =
             Models.capabilities(ctx, @ref, "m", "sha256:w", run: windowless)

    assert {:error, {:describe_failed, :boom}} =
             Models.capabilities(ctx, @ref, "m", "sha256:f", run: fn _ -> {:error, :boom} end)
  end
end
