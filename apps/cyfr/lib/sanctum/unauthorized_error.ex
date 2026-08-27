# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.UnauthorizedError do
  @moduledoc """
  Raised when a context lacks required permissions or access level.

  Carries a `Plug.Exception` status of 403, so a raise that escapes to the
  endpoint renders as the authorization refusal it is — never a 500. The
  MCP surface additionally maps it to the `:insufficient_permissions`
  JSON-RPC code (the controller's rescue for the request process, the tool
  registry's task boundary for handlers).
  """

  defexception [:permission, :action, :message]

  @impl true
  def exception(opts) do
    cond do
      Keyword.has_key?(opts, :permission) ->
        permission = Keyword.fetch!(opts, :permission)
        msg = "Missing required permission: #{permission}"
        %__MODULE__{permission: permission, action: nil, message: msg}

      Keyword.has_key?(opts, :action) ->
        action = Keyword.fetch!(opts, :action)
        msg = "Unauthorized for action: #{action}"
        %__MODULE__{permission: nil, action: action, message: msg}

      true ->
        %__MODULE__{permission: nil, action: nil, message: "Unauthorized"}
    end
  end
end

defimpl Plug.Exception, for: Sanctum.UnauthorizedError do
  def status(_exception), do: 403
  def actions(_exception), do: []
end
