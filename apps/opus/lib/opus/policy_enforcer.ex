# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.PolicyEnforcer do
  @moduledoc """
  Policy enforcement for Opus component execution.

  Validates that components have appropriate policies configured
  before execution. For Catalysts, this ensures that at least one
  capability (`allowed_domains` or `allowed_paths`) is
  explicitly configured.

  ## Enforcement Model

  - **Reagents**: No policy needed (no network access)
  - **Formulas**: No policy needed (no network access)
  - **Catalysts**: Must have at least one capability (`allowed_domains` or `allowed_paths`)

  ## Usage

      ctx = Sanctum.TestContext.local()
      policy = Sanctum.Policy.default()

      # Check if execution is allowed
      {:ok, _policy} = Opus.PolicyEnforcer.validate_execution(ctx, "stripe-catalyst", :catalyst)

      # Check if a specific domain would be allowed
      :ok = Opus.PolicyEnforcer.check_domain(policy, "api.stripe.com")

  """

  alias Sanctum.Policy

  @type component_type :: :catalyst | :reagent | :formula

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Check if a specific domain is allowed by the policy.

  Returns `:ok` or `{:error, reason}`.

  ## Examples

      iex> policy = %Sanctum.Policy{allowed_domains: ["api.stripe.com"]}
      iex> Opus.PolicyEnforcer.check_domain(policy, "api.stripe.com")
      :ok

      iex> policy = %Sanctum.Policy{allowed_domains: ["api.stripe.com"]}
      iex> Opus.PolicyEnforcer.check_domain(policy, "evil.com")
      {:error, "Error: Policy violation - domain \\"evil.com\\" not in allowed_domains\\nAllowed: api.stripe.com"}

  """
  @spec check_domain(Policy.t(), String.t()) :: :ok | {:error, String.t()}
  def check_domain(%Policy{} = policy, domain) when is_binary(domain) do
    if Policy.allows_domain?(policy, domain) do
      :ok
    else
      allowed_list = Enum.join(policy.allowed_domains, ", ")

      {:error,
       "Error: Policy violation - domain \"#{domain}\" not in allowed_domains\nAllowed: #{allowed_list}"}
    end
  end

  @doc """
  Check if a URL scheme is allowed by the policy.

  Returns `:ok` or `{:error, reason}`. Policies with no scheme allowlist
  (nil) allow every scheme — the behavior of every policy stored today.
  """
  @spec check_scheme(Policy.t(), String.t()) :: :ok | {:error, String.t()}
  def check_scheme(%Policy{} = policy, scheme) when is_binary(scheme) do
    if Policy.allows_scheme?(policy, scheme) do
      :ok
    else
      allowed_list = Enum.join(policy.allowed_schemes || [], ", ")

      {:error,
       "Error: Policy violation - scheme \"#{scheme}\" not in allowed_schemes\nAllowed: #{allowed_list}"}
    end
  end

  @doc """
  Check if an HTTP method is allowed by the policy.

  Returns `:ok` or `{:error, reason}`.

  ## Examples

      iex> policy = %Sanctum.Policy{allowed_methods: ["GET", "POST"]}
      iex> Opus.PolicyEnforcer.check_method(policy, "GET")
      :ok

      iex> policy = %Sanctum.Policy{allowed_methods: ["GET"]}
      iex> Opus.PolicyEnforcer.check_method(policy, "DELETE")
      {:error, "Error: Policy violation - method \\"DELETE\\" not in allowed_methods\\nAllowed: GET"}

  """
  @spec check_method(Policy.t(), String.t()) :: :ok | {:error, String.t()}
  def check_method(%Policy{} = policy, method) when is_binary(method) do
    if Policy.allows_method?(policy, method) do
      :ok
    else
      allowed_list = Enum.join(policy.allowed_methods, ", ")

      {:error,
       "Error: Policy violation - method \"#{String.upcase(method)}\" not in allowed_methods\nAllowed: #{allowed_list}"}
    end
  end

  @doc """
  Check both domain and method in a single call.

  Useful for HTTP request validation.

  ## Examples

      iex> policy = %Sanctum.Policy{allowed_domains: ["api.stripe.com"], allowed_methods: ["GET"]}
      iex> Opus.PolicyEnforcer.check_http_request(policy, "api.stripe.com", "GET")
      :ok

      iex> policy = %Sanctum.Policy{allowed_domains: ["api.stripe.com"], allowed_methods: ["GET"]}
      iex> Opus.PolicyEnforcer.check_http_request(policy, "evil.com", "GET")
      {:error, "Error: Policy violation - domain \\"evil.com\\" not in allowed_domains\\nAllowed: api.stripe.com"}

  """
  @spec check_http_request(Policy.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def check_http_request(%Policy{} = policy, domain, method)
      when is_binary(domain) and is_binary(method) do
    with :ok <- check_domain(policy, domain),
         :ok <- check_method(policy, method) do
      :ok
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================
end
