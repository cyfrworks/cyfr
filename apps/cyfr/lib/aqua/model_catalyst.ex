# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ModelCatalyst do
  @moduledoc """
  Which provider protocol a model catalyst speaks — by the catalyst's
  NAME, never by a substring of its reference.

  An unknown catalyst returns a typed refusal before the turn starts.

  This table is transitional: it is the exact-name shim the model
  contract replaces, and it goes when the guest does.
  """

  @protocols %{
    "claude" => :claude,
    "openai" => :openai,
    "gemini" => :gemini,
    "grok" => :grok,
    "openrouter" => :openrouter
  }

  @doc "The catalyst names this table knows."
  @spec names() :: [String.t()]
  def names, do: @protocols |> Map.keys() |> Enum.sort()

  @doc """
  The protocol for a resolved model catalyst reference. A nil reference
  is an agent that pins no model and rides the engine's default.
  """
  @spec protocol(String.t() | nil) ::
          {:ok, atom() | nil} | {:error, {:unsupported_model_catalyst, String.t()}}
  def protocol(nil), do: {:ok, nil}

  def protocol(ref) when is_binary(ref) do
    with {:ok, %{name: name}} <- Sanctum.ComponentRef.parse(ref),
         {:ok, protocol} <- Map.fetch(@protocols, name) do
      {:ok, protocol}
    else
      _ -> {:error, {:unsupported_model_catalyst, ref}}
    end
  end
end
