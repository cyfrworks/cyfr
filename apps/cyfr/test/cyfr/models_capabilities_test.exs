# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ModelsCapabilitiesTest do
  @moduledoc """
  A model's capabilities are its catalyst's `describe` of that model: the
  window, the output ceiling and the input ceiling come from the answer,
  a malformed ceiling reads as absent, a model the catalyst does not know
  and a describe that fails are errors, an answer with no window is an
  error whatever else it carries, and only a reading that succeeded is
  cached, under the key it ran with.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Models

  @ref "catalyst:local.claude:1.3.1"

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
           "max_output_tokens" => 32_000,
           "max_input_tokens" => 400_000
         })}
      end)

    assert {:ok,
            %{
              context_window: 500_000,
              max_output_tokens: 32_000,
              max_input_tokens: 400_000,
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

  test "an input ceiling is read only as a positive integer; anything else is absent, not zero",
       %{ctx: ctx} do
    # Each reading runs under its own key so no case reads another's cache.
    for {reported, expected, digest} <- [
          {:absent, nil, "sha256:absent"},
          {400_000, 400_000, "sha256:present"},
          {0, nil, "sha256:zero"},
          {-1, nil, "sha256:negative"},
          {"400000", nil, "sha256:string"},
          {400_000.0, nil, "sha256:float"},
          {nil, nil, "sha256:null"}
        ] do
      data = %{"model" => "m", "context_window" => 500_000}
      data = if reported == :absent, do: data, else: Map.put(data, "max_input_tokens", reported)
      run = fn _ -> {:ok, envelope(data)} end

      assert {:ok, %{context_window: 500_000, max_input_tokens: ^expected}} =
               Models.capabilities(ctx, @ref, "m", digest, run: run)
    end
  end

  test "an input ceiling never stands in for the window: a model with one and no window refuses",
       %{ctx: ctx} do
    {ceiling_only, runs} =
      counted(fn _ ->
        {:ok, envelope(%{"model" => "m", "max_input_tokens" => 400_000, "streaming" => true})}
      end)

    assert {:error, {:no_context_window, "m"}} =
             Models.capabilities(ctx, @ref, "m", "sha256:c", run: ceiling_only)

    # The refusal is not cached: the next reading runs the catalyst again.
    assert {:error, {:no_context_window, "m"}} =
             Models.capabilities(ctx, @ref, "m", "sha256:c", run: ceiling_only)

    assert runs.() == 2
  end
end
