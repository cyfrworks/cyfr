# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Runner.Admission do
  @moduledoc """
  What a send is held to before anything is written, in order: the text
  and its size, the sender's standing (the athanor open, the sender its
  person), and the agent it addresses — every message addresses one. Only
  the name is decided here; the agent resolves inside the turn.
  """

  alias Aqua.Roster
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Users}

  # One human line, in bytes: the one bound every sender passes through.
  @max_message_bytes 32 * 1024

  @type decision :: {:turn, String.t()}

  @doc """
  Admit `text` from `ctx` into the thread, or refuse it with the
  reason the sender is told: `:empty`, `:message_too_long`, `:archived`,
  `:not_member`, `:no_agent`. `opts`: `:attachments`,
  `:agents` (the sender's roster), `:agent` (an explicit
  pick). Answers the decision and the trimmed text.
  """
  @spec check(Context.t(), String.t(), String.t(), keyword()) ::
          {:ok, decision(), String.t()} | {:error, term()}
  def check(%Context{} = ctx, athanor_id, text, opts) do
    text = String.trim(text || "")
    attachments = Keyword.get(opts, :attachments, [])

    cond do
      text == "" and attachments == [] -> {:error, :empty}
      byte_size(text) > @max_message_bytes -> {:error, :message_too_long}
      true -> with :ok <- standing(ctx, athanor_id), do: address(text, opts)
    end
  end

  @doc "The athanor is open and the caller's own."
  @spec standing(Context.t(), String.t()) ::
          :ok | {:error, :archived | :not_member | :unavailable}
  def standing(%Context{user_id: user_id} = ctx, athanor_id) do
    cond do
      ctx.athanor_id != athanor_id ->
        {:error, :not_member}

      not Athanors.active?(athanor_id) ->
        {:error, :archived}

      not Users.own_athanor?(user_id, athanor_id) ->
        {:error, :not_member}

      true ->
        case Sanctum.Tenancy.revalidate(ctx) do
          {:ok, %Context{authenticated: true, athanor_id: ^athanor_id}} -> :ok
          {:ok, _} -> {:error, :not_member}
          {:error, :unavailable} = error -> error
        end
    end
  end

  defp address(text, opts) do
    roster = Keyword.get(opts, :agents, [])
    {_stripped, mentioned} = Roster.parse_mention(text, roster)

    case pick(roster, mentioned, Keyword.get(opts, :agent), Keyword.get(opts, :last)) do
      {:ok, name} -> {:ok, {:turn, name}, text}
      {:error, _} = error -> error
    end
  end

  # `@name` in the text wins, then an explicit pick, then the agent of the
  # previous turn, then the athanor's first (the roster lists the soul
  # first).
  defp pick(roster, mentioned, explicit, last) do
    cond do
      match?(%{"name" => n} when is_binary(n), mentioned) -> {:ok, mentioned["name"]}
      match?(%{"name" => n} when is_binary(n), explicit) -> {:ok, explicit["name"]}
      is_binary(explicit) and explicit != "" -> {:ok, explicit}
      is_binary(last) -> {:ok, last}
      match?(%{"name" => n} when is_binary(n), List.first(roster)) -> {:ok, hd(roster)["name"]}
      true -> {:error, :no_agent}
    end
  end
end
