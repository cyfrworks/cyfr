defmodule Sanctum.Policy do
  @moduledoc """
  Host Policy configuration for CYFR.

  Policies define what components are allowed to do at runtime. Opus enforces
  these policies—components never see them.

  ## Policy Storage

  Policies are stored in SQLite via `Sanctum.PolicyStore`. When no policy
  exists for a component, the default (deny-all for domains) is used.

  ## Host Policy Fields

  These are enforced by Opus at the WASI boundary:

  | Field | Type | Description |
  |-------|------|-------------|
  | `allowed_domains` | list(string) | Domains the component can reach |
  | `rate_limit` | map | `%{requests: int, window: string}` |
  | `timeout` | string | Max execution time (e.g., "30s") |
  | `max_memory_bytes` | integer | Max WASM memory |
  | `max_request_size` | integer | Max input size in bytes (default 1MB) |
  | `max_response_size` | integer | Max output size in bytes (default 5MB) |
  | `allowed_tools` | list(string) | MCP tools the component can call (deny-by-default) |
  | `allowed_storage_paths` | list(string) | Storage path prefixes allowed (empty = no restriction) |

  ## Usage

      # Load effective policy for a component
      {:ok, policy} = Sanctum.Policy.get_effective(ctx, "stripe-catalyst")

      # Check if domain is allowed
      Sanctum.Policy.allows_domain?(policy, "api.stripe.com")
      #=> true

  """

  alias Sanctum.Context

  @type t :: %__MODULE__{
          allowed_domains: [String.t()],
          allowed_methods: [String.t()],
          rate_limit: %{requests: non_neg_integer(), window: String.t()} | nil,
          timeout: String.t(),
          max_memory_bytes: non_neg_integer(),
          max_request_size: non_neg_integer(),
          max_response_size: non_neg_integer(),
          allowed_tools: [String.t()],
          allowed_storage_paths: [String.t()]
        }

  @default_allowed_methods ["GET", "POST", "PUT", "DELETE", "PATCH"]

  defstruct allowed_domains: [],
            allowed_methods: @default_allowed_methods,
            rate_limit: nil,
            timeout: "30s",
            max_memory_bytes: 64 * 1024 * 1024,
            max_request_size: 1_048_576,    # 1MB default
            max_response_size: 5_242_880,   # 5MB default
            allowed_tools: [],              # deny-by-default for MCP tools
            allowed_storage_paths: []       # empty = no restriction

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Get the effective policy for a component reference.

  Looks up the policy from SQLite via PolicyStore. If no policy exists,
  returns the default (deny-all for domains).

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> {:ok, policy} = Sanctum.Policy.get_effective(ctx, "stripe-catalyst")
      iex> policy.allowed_domains
      ["api.stripe.com"]

  """
  @spec get_effective(Context.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def get_effective(%Context{} = _ctx, component_ref) when is_binary(component_ref) do
    case Sanctum.PolicyStore.get(component_ref) do
      {:ok, policy} -> {:ok, policy}
      {:error, :not_found} -> {:ok, default()}
    end
  end

  @doc """
  Get the default (most restrictive) policy.

  Used when no policy exists for a component.
  """
  @spec default() :: t()
  def default do
    %__MODULE__{
      allowed_domains: [],
      allowed_methods: @default_allowed_methods,
      rate_limit: %{requests: 100, window: "1m"},
      timeout: "30s",
      max_memory_bytes: 64 * 1024 * 1024,
      max_request_size: 1_048_576,    # 1MB
      max_response_size: 5_242_880    # 5MB
    }
  end

  @doc """
  Check if a domain is allowed by the policy.

  Supports wildcard matching (e.g., "*.stripe.com" matches "api.stripe.com").

  ## Examples

      iex> policy = %Sanctum.Policy{allowed_domains: ["api.stripe.com"]}
      iex> Sanctum.Policy.allows_domain?(policy, "api.stripe.com")
      true

      iex> policy = %Sanctum.Policy{allowed_domains: ["*.stripe.com"]}
      iex> Sanctum.Policy.allows_domain?(policy, "api.stripe.com")
      true

      iex> policy = %Sanctum.Policy{allowed_domains: []}
      iex> Sanctum.Policy.allows_domain?(policy, "evil.com")
      false

  """
  @spec allows_domain?(t(), String.t()) :: boolean()
  def allows_domain?(%__MODULE__{allowed_domains: domains}, domain) when is_binary(domain) do
    Enum.any?(domains, fn pattern ->
      domain_matches?(pattern, domain)
    end)
  end

  @doc """
  Check if an HTTP method is allowed by the policy.

  ## Examples

      iex> policy = %Sanctum.Policy{allowed_methods: ["GET", "POST"]}
      iex> Sanctum.Policy.allows_method?(policy, "GET")
      true

      iex> policy = %Sanctum.Policy{allowed_methods: ["GET", "POST"]}
      iex> Sanctum.Policy.allows_method?(policy, "DELETE")
      false

      iex> policy = %Sanctum.Policy{allowed_methods: ["GET"]}
      iex> Sanctum.Policy.allows_method?(policy, "get")
      true

  """
  @spec allows_method?(t(), String.t()) :: boolean()
  def allows_method?(%__MODULE__{allowed_methods: methods}, method) when is_binary(method) do
    upcase_method = String.upcase(method)
    Enum.any?(methods, fn allowed ->
      String.upcase(allowed) == upcase_method
    end)
  end

  @doc """
  Check if an MCP tool action is allowed by the policy.

  Supports exact match (e.g., "component.search") and wildcard (e.g., "component.*").
  Empty `allowed_tools` list means deny-all (no tools allowed).

  ## Examples

      iex> policy = %Sanctum.Policy{allowed_tools: ["component.search"]}
      iex> Sanctum.Policy.allows_tool?(policy, "component.search")
      true

      iex> policy = %Sanctum.Policy{allowed_tools: ["component.*"]}
      iex> Sanctum.Policy.allows_tool?(policy, "component.search")
      true

      iex> policy = %Sanctum.Policy{allowed_tools: []}
      iex> Sanctum.Policy.allows_tool?(policy, "component.search")
      false

  """
  @spec allows_tool?(t(), String.t()) :: boolean()
  def allows_tool?(%__MODULE__{allowed_tools: tools}, tool_action) when is_binary(tool_action) do
    Enum.any?(tools, fn pattern ->
      tool_matches?(pattern, tool_action)
    end)
  end

  @doc """
  Check if a storage path is allowed by the policy.

  Uses prefix matching. Empty `allowed_storage_paths` list means no restriction
  (all paths allowed).

  ## Examples

      iex> policy = %Sanctum.Policy{allowed_storage_paths: ["agent/"]}
      iex> Sanctum.Policy.allows_storage_path?(policy, "agent/data.json")
      true

      iex> policy = %Sanctum.Policy{allowed_storage_paths: ["agent/"]}
      iex> Sanctum.Policy.allows_storage_path?(policy, "secrets/key.json")
      false

      iex> policy = %Sanctum.Policy{allowed_storage_paths: []}
      iex> Sanctum.Policy.allows_storage_path?(policy, "anything/path")
      true

  """
  @spec allows_storage_path?(t(), String.t()) :: boolean()
  def allows_storage_path?(%__MODULE__{allowed_storage_paths: []}, _path), do: true

  def allows_storage_path?(%__MODULE__{allowed_storage_paths: paths}, path) when is_binary(path) do
    Enum.any?(paths, fn prefix ->
      String.starts_with?(path, prefix)
    end)
  end

  @doc """
  Check if an operation is within rate limits.

  Returns `{:ok, remaining}` if allowed, `{:error, :rate_limited, retry_after_ms}` if exceeded.

  Delegates to `Opus.RateLimiter` for stateful sliding window rate limiting.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> policy = %Sanctum.Policy{rate_limit: %{requests: 100, window: "1m"}}
      iex> {:ok, remaining} = Sanctum.Policy.check_rate_limit(policy, ctx, "my-component")
      iex> is_integer(remaining) or remaining == :unlimited
      true

  """
  @spec check_rate_limit(t(), Context.t(), String.t()) ::
          {:ok, non_neg_integer() | :unlimited} | {:error, :rate_limited, non_neg_integer()}
  def check_rate_limit(%__MODULE__{rate_limit: nil}, _ctx, _component_ref), do: {:ok, :unlimited}

  def check_rate_limit(%__MODULE__{} = policy, %Context{user_id: user_id}, component_ref) do
    if Code.ensure_loaded?(Opus.RateLimiter) do
      apply(Opus.RateLimiter, :check, [user_id, component_ref, policy])
    else
      {:ok, :unlimited}
    end
  end

  @doc """
  Legacy check_rate_limit/2 for backwards compatibility.

  Deprecated: Use check_rate_limit/3 instead.
  """
  @spec check_rate_limit(t(), String.t()) :: {:ok, non_neg_integer() | :unlimited}
  def check_rate_limit(%__MODULE__{rate_limit: nil}, _operation), do: {:ok, :unlimited}

  def check_rate_limit(%__MODULE__{rate_limit: %{requests: max}}, _operation) do
    {:ok, max}
  end

  @doc """
  Parse timeout string to milliseconds.

  ## Examples

      iex> Sanctum.Policy.timeout_ms(%Sanctum.Policy{timeout: "30s"})
      30_000

      iex> Sanctum.Policy.timeout_ms(%Sanctum.Policy{timeout: "1m"})
      60_000

  """
  @spec timeout_ms(t()) :: non_neg_integer()
  def timeout_ms(%__MODULE__{timeout: timeout}) do
    parse_duration(timeout)
  end

  # ============================================================================
  # Domain Matching
  # ============================================================================

  defp domain_matches?(pattern, domain) when is_binary(pattern) and is_binary(domain) do
    cond do
      pattern == "*" ->
        true

      pattern == domain ->
        true

      String.starts_with?(pattern, "*.") ->
        suffix = String.slice(pattern, 1..-1//1)
        String.ends_with?(domain, suffix)

      true ->
        false
    end
  end

  # ============================================================================
  # Tool Matching
  # ============================================================================

  defp tool_matches?(pattern, tool_action) when is_binary(pattern) and is_binary(tool_action) do
    cond do
      pattern == tool_action ->
        true

      String.ends_with?(pattern, ".*") ->
        prefix = String.slice(pattern, 0..-3//1) <> "."
        String.starts_with?(tool_action, prefix)

      true ->
        false
    end
  end

  # ============================================================================
  # Duration Parsing
  # ============================================================================

  defp parse_duration(duration) when is_binary(duration) do
    cond do
      String.ends_with?(duration, "ms") ->
        duration |> String.trim_trailing("ms") |> String.to_integer()

      String.ends_with?(duration, "s") ->
        (duration |> String.trim_trailing("s") |> String.to_integer()) * 1000

      String.ends_with?(duration, "m") ->
        (duration |> String.trim_trailing("m") |> String.to_integer()) * 60 * 1000

      String.ends_with?(duration, "h") ->
        (duration |> String.trim_trailing("h") |> String.to_integer()) * 60 * 60 * 1000

      true ->
        String.to_integer(duration) * 1000
    end
  rescue
    _ -> 30_000
  end

  defp parse_duration(_), do: 30_000

  # ============================================================================
  # Conversion
  # ============================================================================

  @doc """
  Convert a Policy struct to a plain map (for MCP responses).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = policy) do
    %{
      "allowed_domains" => policy.allowed_domains,
      "allowed_methods" => policy.allowed_methods,
      "rate_limit" => format_rate_limit(policy.rate_limit),
      "timeout" => policy.timeout,
      "max_memory_bytes" => policy.max_memory_bytes,
      "max_request_size" => policy.max_request_size,
      "max_response_size" => policy.max_response_size,
      "allowed_tools" => policy.allowed_tools,
      "allowed_storage_paths" => policy.allowed_storage_paths
    }
  end

  defp format_rate_limit(nil), do: nil
  defp format_rate_limit(%{requests: req, window: win}), do: %{"requests" => req, "window" => win}

  @doc """
  Convert a map to a Policy struct.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      allowed_domains: get_list(map, "allowed_domains"),
      allowed_methods: get_methods(map),
      rate_limit: parse_rate_limit(map["rate_limit"]),
      timeout: map["timeout"] || "30s",
      max_memory_bytes: parse_memory(map["max_memory_bytes"]),
      max_request_size: parse_size(map["max_request_size"], 1_048_576),
      max_response_size: parse_size(map["max_response_size"], 5_242_880),
      allowed_tools: get_list(map, "allowed_tools"),
      allowed_storage_paths: get_list(map, "allowed_storage_paths")
    }
  end

  defp get_methods(map) do
    case Map.get(map, "allowed_methods") do
      nil -> @default_allowed_methods
      methods when is_list(methods) -> Enum.map(methods, &String.upcase/1)
      method when is_binary(method) -> [String.upcase(method)]
    end
  end

  defp get_list(map, key) do
    case Map.get(map, key) do
      nil -> []
      list when is_list(list) -> list
      value when is_binary(value) -> [value]
    end
  end

  defp parse_rate_limit(nil), do: nil

  defp parse_rate_limit(value) when is_binary(value) do
    case String.split(value, "/") do
      [requests, window] ->
        %{requests: String.to_integer(requests), window: window}

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp parse_rate_limit(%{"requests" => req, "window" => win}) do
    %{requests: req, window: win}
  end

  defp parse_rate_limit(_), do: nil

  defp parse_memory(nil), do: 64 * 1024 * 1024

  defp parse_memory(bytes) when is_integer(bytes), do: bytes

  defp parse_memory(str) when is_binary(str) do
    cond do
      String.ends_with?(str, "MB") ->
        (str |> String.trim_trailing("MB") |> String.to_integer()) * 1024 * 1024

      String.ends_with?(str, "GB") ->
        (str |> String.trim_trailing("GB") |> String.to_integer()) * 1024 * 1024 * 1024

      String.ends_with?(str, "KB") ->
        (str |> String.trim_trailing("KB") |> String.to_integer()) * 1024

      true ->
        String.to_integer(str)
    end
  rescue
    _ -> 64 * 1024 * 1024
  end

  defp parse_size(nil, default), do: default
  defp parse_size(bytes, _default) when is_integer(bytes), do: bytes
  defp parse_size(str, default) when is_binary(str) do
    cond do
      String.ends_with?(str, "MB") ->
        (str |> String.trim_trailing("MB") |> String.to_integer()) * 1024 * 1024

      String.ends_with?(str, "GB") ->
        (str |> String.trim_trailing("GB") |> String.to_integer()) * 1024 * 1024 * 1024

      String.ends_with?(str, "KB") ->
        (str |> String.trim_trailing("KB") |> String.to_integer()) * 1024

      true ->
        String.to_integer(str)
    end
  rescue
    _ -> default
  end
end
