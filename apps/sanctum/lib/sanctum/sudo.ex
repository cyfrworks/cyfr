defmodule Sanctum.Sudo do
  @moduledoc """
  Sudo credential verification for sensitive operations.

  Policy Lock requires credential confirmation before:
  - Policy modifications
  - Destructive storage actions
  - Secret management

  ## Configuration

  Enable sudo requirement in config:

      config :sanctum, require_sudo: true

  Set the sudo secret (defaults to session password or env var):

      export CYFR_SUDO_SECRET=your-sudo-secret

  ## Usage

      # In MCP handlers
      with :ok <- Sanctum.Sudo.maybe_require(ctx, args, "secret.set") do
        # perform operation
      end

  """

  alias Sanctum.Context

  @doc """
  Verify sudo credential for a context.

  In Sanctum: verifies against configured secret or env var.
  In Arx Edition: delegates to configured auth provider.

  Returns `:ok` on successful verification, `{:error, reason}` otherwise.
  """
  @spec verify(Context.t(), String.t()) :: :ok | {:error, String.t()}
  def verify(%Context{} = _ctx, credential) when is_binary(credential) do
    expected = get_sudo_secret()

    cond do
      expected == nil ->
        # No sudo secret configured - allow in dev mode
        :ok

      credential == "" ->
        {:error, "sudo_credential cannot be empty"}

      secure_compare(credential, expected) ->
        :ok

      true ->
        {:error, "invalid sudo credential"}
    end
  end

  def verify(_ctx, _credential) do
    {:error, "sudo_credential must be a string"}
  end

  @doc """
  Require sudo verification - raises on failure.

  ## Examples

      Sanctum.Sudo.require!(ctx, "secret123", "secret.set")
      # => :ok

      Sanctum.Sudo.require!(ctx, "wrong", "secret.set")
      # => raises Sanctum.UnauthorizedError

  """
  @spec require!(Context.t(), String.t(), String.t()) :: :ok
  def require!(ctx, credential, operation) do
    case verify(ctx, credential) do
      :ok ->
        :ok

      {:error, reason} ->
        raise Sanctum.UnauthorizedError, action: "Sudo required for #{operation}: #{reason}"
    end
  end

  @doc """
  Conditionally require sudo based on configuration and args.

  If `require_sudo` config is true and no credential provided, returns error.
  If credential is provided, verifies it.
  If `require_sudo` is false (dev mode), allows operation.

  ## Examples

      # With sudo_credential in args
      args = %{"action" => "set", "sudo_credential" => "secret123"}
      :ok = Sanctum.Sudo.maybe_require(ctx, args, "secret.set")

      # Without credential when require_sudo is false
      args = %{"action" => "set"}
      :ok = Sanctum.Sudo.maybe_require(ctx, args, "secret.set")

      # Without credential when require_sudo is true
      args = %{"action" => "set"}
      {:error, "sudo_credential required..."} = Sanctum.Sudo.maybe_require(ctx, args, "secret.set")

  """
  @spec maybe_require(Context.t(), map(), String.t()) :: :ok | {:error, String.t()}
  def maybe_require(ctx, %{"sudo_credential" => cred}, _operation) when is_binary(cred) do
    verify(ctx, cred)
  end

  def maybe_require(_ctx, _args, operation) do
    if require_sudo?() do
      {:error, "sudo_credential required for #{operation}"}
    else
      :ok
    end
  end

  @doc """
  Check if sudo is required for operations.
  """
  @spec require_sudo?() :: boolean()
  def require_sudo? do
    Application.get_env(:sanctum, :require_sudo, false)
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp get_sudo_secret do
    Application.get_env(:sanctum, :sudo_secret) ||
      System.get_env("CYFR_SUDO_SECRET")
  end

  # Constant-time string comparison to prevent timing attacks
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    if byte_size(a) == byte_size(b) do
      :crypto.hash_equals(a, b)
    else
      false
    end
  end
end
