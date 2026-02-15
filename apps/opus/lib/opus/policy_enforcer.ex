defmodule Opus.PolicyEnforcer do
  @moduledoc """
  Policy enforcement for Opus component execution.

  Validates that components have appropriate policies configured
  before execution. For Catalysts (which have HTTP capabilities),
  this ensures that `allowed_domains` is explicitly configured.

  ## Enforcement Model

  - **Reagents**: No policy needed (no network access)
  - **Formulas**: No policy needed (no network access)
  - **Catalysts**: Must have `allowed_domains` configured

  ## Usage

      ctx = Sanctum.Context.local()
      policy = Sanctum.Policy.default()

      # Check if execution is allowed
      :ok = Opus.PolicyEnforcer.validate_execution(ctx, "stripe-catalyst", :catalyst)

      # Check if a specific domain would be allowed
      :ok = Opus.PolicyEnforcer.check_domain(policy, "api.stripe.com")

  """

  alias Sanctum.{Context, Policy}

  @type component_type :: :catalyst | :reagent | :formula

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Validate that a component can be executed with the current policy.

  For Catalysts, this checks that:
  1. A policy exists for the component
  2. The policy has explicit `allowed_domains` configured

  Returns `:ok` or `{:error, reason}`.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Opus.PolicyEnforcer.validate_execution(ctx, "stripe-catalyst", :catalyst)
      :ok

      iex> ctx = Sanctum.Context.local()
      iex> Opus.PolicyEnforcer.validate_execution(ctx, "unknown", :catalyst)
      {:error, "Catalyst 'unknown' has no allowed_domains configured. ..."}

  """
  @spec validate_execution(Context.t(), String.t(), component_type()) ::
          :ok | {:ok, Policy.t()} | {:error, String.t()}
  def validate_execution(%Context{} = ctx, component_ref, component_type) do
    case component_type do
      :reagent ->
        # Reagents have no network access - always allowed
        :ok

      :formula ->
        # Formulas have no network access - always allowed
        :ok

      :catalyst ->
        # Catalysts need explicit policy — returns {:ok, policy} to avoid re-fetching
        validate_catalyst_policy(ctx, component_ref)
    end
  end

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

  @doc """
  Get the effective policy for a component (via MCP boundary).
  """
  @spec get_policy(Context.t(), String.t()) :: {:ok, Policy.t()} | {:error, term()}
  def get_policy(%Context{} = ctx, component_ref) do
    case Sanctum.MCP.handle("policy", ctx, %{"action" => "get_effective", "component_ref" => component_ref}) do
      {:ok, policy_map} ->
        case Policy.from_map(policy_map) do
          {:ok, policy} -> {:ok, policy}
          {:error, reason} -> {:error, "Invalid policy for '#{component_ref}': #{reason}"}
        end
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Build execution options with policy constraints.

  Returns options to pass to `Opus.Runtime.execute_component/3`,
  including policy-derived settings like timeout and memory limits.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> {:ok, opts} = Opus.PolicyEnforcer.build_execution_opts(ctx, "stripe-catalyst", :catalyst)
      iex> opts[:timeout_ms]
      30000

  """
  @spec build_execution_opts(Context.t(), String.t(), component_type()) ::
          {:ok, keyword()} | {:error, String.t()}
  def build_execution_opts(%Context{} = ctx, component_ref, component_type) do
    # For catalysts, validate_execution returns {:ok, policy} to avoid a redundant
    # MCP round-trip (validate_catalyst_policy already fetches the policy).
    with validation_result <- validate_execution(ctx, component_ref, component_type),
         {:ok, policy} <- resolve_policy(validation_result, ctx, component_ref),
         {:ok, timeout} <- Policy.timeout_ms(policy) do
      opts = [
        component_type: component_type,
        timeout_ms: timeout,
        max_memory_bytes: policy.max_memory_bytes,
        policy: policy
      ]

      {:ok, opts}
    end
  end

  # Catalyst validation already fetched the policy — reuse it
  defp resolve_policy({:ok, %Policy{} = policy}, _ctx, _ref), do: {:ok, policy}
  # Reagent/Formula validation returns :ok — fetch policy separately
  defp resolve_policy(:ok, ctx, component_ref), do: get_policy(ctx, component_ref)
  # Propagate errors
  defp resolve_policy({:error, _} = error, _ctx, _ref), do: error

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp validate_catalyst_policy(ctx, component_ref) do
    case get_policy(ctx, component_ref) do
      {:ok, %Policy{allowed_domains: []}} ->
        {:error,
         """
         Catalyst '#{component_ref}' has no allowed_domains configured.

         Catalysts can make HTTP requests, so you must explicitly configure
         which domains they can access:

           cyfr policy set #{component_ref} allowed_domains '["api.example.com"]'
         """}

      {:ok, %Policy{allowed_domains: domains} = policy} when is_list(domains) and domains != [] ->
        {:ok, policy}

      {:error, reason} ->
        {:error, "Failed to load policy for '#{component_ref}': #{inspect(reason)}"}
    end
  end
end
