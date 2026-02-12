defmodule Sanctum.UnauthorizedError do
  @moduledoc """
  Raised when a context lacks required permissions or access level.
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
