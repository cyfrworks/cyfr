defmodule Arca.AccessLevel do
  @moduledoc """
  Access level enforcement for Arca storage operations.

  Defines required access levels per action as specified in PRD:
  - `read` and `list` are `application` level (any valid key)
  - `write` and `delete` are `admin` level (admin keys or OIDC session only)

  ## Usage

      iex> Arca.AccessLevel.required_level(:list)
      :application

      iex> Arca.AccessLevel.required_level(:write)
      :admin

      iex> Arca.AccessLevel.authorized?(ctx, :read)
      true

  """

  alias Sanctum.Context

  @type access_level :: :application | :admin
  @type action :: :list | :read | :write | :delete

  @action_levels %{
    list: :application,
    read: :application,
    write: :admin,
    delete: :admin
  }

  @doc """
  Returns the required access level for a given action.

  ## Examples

      iex> Arca.AccessLevel.required_level(:read)
      :application

      iex> Arca.AccessLevel.required_level(:delete)
      :admin

  """
  @spec required_level(action()) :: access_level()
  def required_level(action) when is_atom(action) do
    Map.get(@action_levels, action, :admin)
  end

  def required_level(action) when is_binary(action) do
    action |> String.to_existing_atom() |> required_level()
  rescue
    ArgumentError -> :admin
  end

  @doc """
  Check if a context is authorized for a given action.

  Authorization rules:
  - `:application` level: any valid context (valid API key or OIDC session)
  - `:admin` level: admin API key, or OIDC session, or local context with wildcard permissions

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Arca.AccessLevel.authorized?(ctx, :read)
      true

  """
  @spec authorized?(Context.t(), action()) :: boolean()
  def authorized?(%Context{} = ctx, action) do
    required = required_level(action)
    context_level = get_context_level(ctx)

    case {required, context_level} do
      # Application level allows any authenticated context
      {:application, _} -> true
      # Admin level requires admin context
      {:admin, :admin} -> true
      {:admin, _} -> false
    end
  end

  @doc """
  Authorize a context for an action, returning an error tuple if unauthorized.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Arca.AccessLevel.authorize(ctx, :read)
      :ok

      iex> ctx = %Sanctum.Context{user_id: "user", api_key_type: :application}
      iex> Arca.AccessLevel.authorize(ctx, :write)
      {:error, :unauthorized}

  """
  @spec authorize(Context.t(), action()) :: :ok | {:error, :unauthorized}
  def authorize(%Context{} = ctx, action) do
    if authorized?(ctx, action) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Authorize a context for an action, raising if unauthorized.
  """
  @spec authorize!(Context.t(), action()) :: :ok
  def authorize!(%Context{} = ctx, action) do
    case authorize(ctx, action) do
      :ok -> :ok
      {:error, :unauthorized} -> raise Sanctum.UnauthorizedError, action: action
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  # Determine the effective access level of a context
  defp get_context_level(%Context{} = ctx) do
    cond do
      # Local context with wildcard permissions is admin
      Context.has_permission?(ctx, :*) -> :admin
      # OIDC session (auth_method: :oidc) is admin
      Map.get(ctx, :auth_method) == :oidc -> :admin
      # Admin API key type is admin
      Map.get(ctx, :api_key_type) == :admin -> :admin
      # Secret API key type is admin
      Map.get(ctx, :api_key_type) == :secret -> :admin
      # Application API key is application level
      Map.get(ctx, :api_key_type) == :application -> :application
      # Public API key is application level
      Map.get(ctx, :api_key_type) == :public -> :application
      # Unknown - default to application (most restrictive for unknown)
      true -> :application
    end
  end
end
