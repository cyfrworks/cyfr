# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AuthHelpers do
  @moduledoc """
  The web adapter over `Sanctum.Caller` for LiveView hooks and
  controller plugs: establish the caller, tag the logger, and hand the
  named refusals to whoever must map them to a redirect or a status.
  """

  alias Sanctum.{Caller, Context}

  @doc """
  Establish the caller behind a session token. With an `athanor_id`, the
  context is focused on that athanor (`Sanctum.Context.focus/2`) — how a
  nested LiveView rendered by the layout (topbar, AQUA overlay) follows
  the page's focus, since it mounts with the session and no URL.

  Returns `{:ok, ctx}` or `{:error, Sanctum.Caller.refusal()}`.
  """
  @spec authenticate_session(String.t() | nil, String.t() | nil) ::
          {:ok, Context.t()} | {:error, Caller.refusal()}
  def authenticate_session(token, athanor_id \\ nil) do
    case Caller.establish(token, focus: athanor_id, task_supervisor: Prism.TaskSupervisor) do
      {:ok, ctx} ->
        Cyfr.LoggerContext.set_from_context(ctx)
        {:ok, ctx}

      {:error, _} = refusal ->
        refusal
    end
  end
end
