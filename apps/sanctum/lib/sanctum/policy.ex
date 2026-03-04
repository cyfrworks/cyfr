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
  | `allowed_paths` | list(string) | Directory prefixes the catalyst can access (must end with `/`, e.g. `"data/"`, `"components/catalysts/"`). Use `"*"` for all scopes. Empty = deny all. |
  | `allowed_actions` | list(string) | Storage actions the catalyst can perform (`read`, `write`, `list`, `delete`, `exists`). Empty = deny all. |
  | `batch_timeout` | string | Max time for await-all/await-any operations (e.g., "5m") |
  | `max_concurrent_tasks` | integer | Max spawned async tasks per formula execution (0=unlimited) |
  | `allowed_private_ips` | list(string) | Private IPs/CIDRs allowed for HTTP requests (empty = deny all) |

  ## Usage

      # Load effective policy for a component
      {:ok, policy} = Sanctum.Policy.get_effective(ctx, "stripe-catalyst")

      # Check if domain is allowed
      Sanctum.Policy.allows_domain?(policy, "api.stripe.com")
      #=> true

  """

  require Logger

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
          allowed_paths: [String.t()],
          allowed_actions: [String.t()],
          batch_timeout: String.t(),
          max_concurrent_tasks: non_neg_integer(),
          allowed_private_ips: [String.t()]
        }

  @type_defaults %{
    catalyst: %{
      allowed_domains: [],
      allowed_methods: [],
      rate_limit: %{requests: 100, window: "1m"},
      timeout: "3m",
      max_memory_bytes: 64 * 1024 * 1024,
      max_request_size: 1_048_576,
      max_response_size: 5_242_880,
      allowed_tools: [],
      allowed_paths: [],
      allowed_actions: [],
      batch_timeout: "5m",
      max_concurrent_tasks: 10,
      allowed_private_ips: []
    },
    formula: %{
      allowed_domains: [],
      allowed_methods: [],
      rate_limit: %{requests: 100, window: "1m"},
      timeout: "5m",
      max_memory_bytes: 64 * 1024 * 1024,
      max_request_size: 1_048_576,
      max_response_size: 5_242_880,
      allowed_tools: [],
      allowed_paths: [],
      batch_timeout: "5m",
      max_concurrent_tasks: 10,
      allowed_private_ips: []
    },
    reagent: %{
      allowed_domains: [],
      allowed_methods: [],
      rate_limit: %{requests: 100, window: "1m"},
      timeout: "1m",
      max_memory_bytes: 64 * 1024 * 1024,
      max_request_size: 1_048_576,
      max_response_size: 5_242_880,
      allowed_tools: [],
      allowed_paths: [],
      batch_timeout: "5m",
      max_concurrent_tasks: 10,
      allowed_private_ips: []
    }
  }

  defstruct allowed_domains: [],
            allowed_methods: [],
            rate_limit: nil,
            timeout: "1m",
            max_memory_bytes: 64 * 1024 * 1024,
            max_request_size: 1_048_576,    # 1MB default
            max_response_size: 5_242_880,   # 5MB default
            allowed_tools: [],              # deny-by-default for MCP tools
            allowed_paths: [],              # "data/" (prefix), "data/file.json" (exact), or "*" (all). empty = deny all
            allowed_actions: [],            # storage actions: read, write, list, delete, exists. empty = deny all
            batch_timeout: "5m",            # max time for await-all/await-any
            max_concurrent_tasks: 10,       # max spawned tasks per formula execution
            allowed_private_ips: []         # private IPs/CIDRs allowed (empty = deny all)

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
      {:ok, policy} ->
        {:ok, policy}

      {:error, :not_found} ->
        {:ok, default_for_ref(component_ref)}

      {:error, reason} when is_binary(reason) ->
        # String errors come from ComponentRef.normalize (missing type prefix,
        # missing version). These are input normalization failures, not storage
        # errors — safe to fall back to type-aware default policy.
        Logger.warning("[Sanctum.Policy] Ref normalization failed for #{component_ref}: #{reason}. Falling back to default policy.")
        {:ok, default_for_ref(component_ref)}

      {:error, {:store_error, reason}} ->
        Logger.error("[Sanctum.Policy] Storage error looking up policy for #{component_ref}: #{inspect(reason)}")
        {:error, {:store_error, reason}}

      {:error, {:corrupt_policy, reason}} ->
        Logger.error("[Sanctum.Policy] Corrupt policy for #{component_ref}: #{inspect(reason)}")
        {:error, {:corrupt_policy, reason}}

      {:error, reason} ->
        Logger.error("[Sanctum.Policy] Unexpected error for #{component_ref}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp default_for_ref(component_ref) do
    case Sanctum.ComponentRef.parse(component_ref) do
      {:ok, %{type: type}} when type in ["catalyst", "formula", "reagent"] ->
        type_atom = String.to_existing_atom(type)

        case Sanctum.PolicyStore.get_type_default(type_atom) do
          {:ok, policy} -> policy
          {:error, :not_found} -> default(type_atom)
        end

      _ ->
        default()
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
      allowed_methods: [],
      rate_limit: %{requests: 100, window: "1m"},
      timeout: "1m",
      max_memory_bytes: 64 * 1024 * 1024,
      max_request_size: 1_048_576,    # 1MB
      max_response_size: 5_242_880,   # 5MB
      allowed_actions: [],
      batch_timeout: "5m",
      max_concurrent_tasks: 10,
      allowed_private_ips: []
    }
  end

  @doc """
  Get the default policy for a specific component type.

  Uses type-specific timeout defaults:
  - catalyst: 3m (HTTP operations)
  - formula: 5m (composition of components)
  - reagent: 1m (pure compute)
  """
  @spec default(atom()) :: t()
  def default(component_type) when component_type in [:catalyst, :formula, :reagent] do
    d = Map.fetch!(@type_defaults, component_type)
    struct(__MODULE__, d)
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
  Check if a storage action is allowed by the policy.

  ## Examples

      iex> policy = %Sanctum.Policy{allowed_actions: ["read", "list", "exists"]}
      iex> Sanctum.Policy.allows_action?(policy, "read")
      true

      iex> policy = %Sanctum.Policy{allowed_actions: ["read", "list", "exists"]}
      iex> Sanctum.Policy.allows_action?(policy, "write")
      false

  """
  @spec allows_action?(t(), String.t()) :: boolean()
  def allows_action?(%__MODULE__{allowed_actions: actions}, action) when is_binary(action) do
    Enum.any?(actions, &(String.downcase(&1) == String.downcase(action)))
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
  Check if a path is allowed by the policy.

  Empty `allowed_paths` list means deny-all.

  ## Resolution

  - `"data/"` — directory prefix, allows everything under `data/`
  - `"data/report.json"` — exact file match
  - `"*"` — allows both `data/` and `components/`

  Bare scope names without `/` (e.g. `"data"`) don't match anything.

  ## Examples

      iex> policy = %Sanctum.Policy{allowed_paths: ["data/reports/"]}
      iex> Sanctum.Policy.allows_path?(policy, "data/reports/2024.json")
      true

      iex> policy = %Sanctum.Policy{allowed_paths: ["data/report.json"]}
      iex> Sanctum.Policy.allows_path?(policy, "data/report.json")
      true

      iex> policy = %Sanctum.Policy{allowed_paths: ["data/report.json"]}
      iex> Sanctum.Policy.allows_path?(policy, "data/other.json")
      false

      iex> policy = %Sanctum.Policy{allowed_paths: []}
      iex> Sanctum.Policy.allows_path?(policy, "data/anything")
      false

      iex> policy = %Sanctum.Policy{allowed_paths: ["*"]}
      iex> Sanctum.Policy.allows_path?(policy, "data/anything")
      true

  """
  @spec allows_path?(t(), String.t()) :: boolean()
  def allows_path?(%__MODULE__{allowed_paths: paths}, path) when is_binary(path) do
    Enum.any?(paths, fn
      "*" -> true
      entry ->
        if String.ends_with?(entry, "/") do
          String.starts_with?(path, entry)
        else
          path == entry
        end
    end)
  end

  @doc """
  Check if a private IP is allowed by the policy's `allowed_private_ips` list.

  Supports individual IPs (`"192.168.1.100"`) and CIDR ranges (`"10.0.0.0/8"`).
  The `169.254.0.0/16` range (link-local / cloud metadata) is always denied
  regardless of the allowlist.

  ## Examples

      iex> policy = %Sanctum.Policy{allowed_private_ips: ["10.0.0.0/8"]}
      iex> Sanctum.Policy.allows_private_ip?(policy, {10, 1, 2, 3})
      true

      iex> policy = %Sanctum.Policy{allowed_private_ips: ["10.0.0.0/8"]}
      iex> Sanctum.Policy.allows_private_ip?(policy, {192, 168, 1, 1})
      false

      iex> policy = %Sanctum.Policy{allowed_private_ips: ["169.254.0.0/16"]}
      iex> Sanctum.Policy.allows_private_ip?(policy, {169, 254, 169, 254})
      false

  """
  @spec allows_private_ip?(t(), :inet.ip4_address() | :inet.ip6_address()) :: boolean()
  def allows_private_ip?(%__MODULE__{allowed_private_ips: []}, _ip_tuple), do: false

  def allows_private_ip?(%__MODULE__{allowed_private_ips: entries}, ip_tuple) do
    # Always block link-local / cloud metadata (169.254.0.0/16)
    if link_local_ip?(ip_tuple) do
      false
    else
      ip_string = :inet.ntoa(ip_tuple) |> to_string()

      Enum.any?(entries, fn entry ->
        ip_entry_matches?(entry, ip_tuple, ip_string)
      end)
    end
  end

  defp link_local_ip?({169, 254, _, _}), do: true
  # IPv4-mapped IPv6 ::ffff:169.254.x.x
  defp link_local_ip?({0, 0, 0, 0, 0, 0xFFFF, ab, _cd}) do
    import Bitwise
    bsr(ab, 8) == 169 and band(ab, 0xFF) == 254
  end
  defp link_local_ip?(_), do: false

  defp ip_entry_matches?(entry, ip_tuple, ip_string) do
    if String.contains?(entry, "/") do
      cidr_matches?(entry, ip_tuple)
    else
      entry == ip_string
    end
  end

  defp cidr_matches?(cidr_string, {a, b, c, d}) do
    import Bitwise

    case parse_cidr_v4(cidr_string) do
      {:ok, base_int, prefix_len} ->
        mask = if prefix_len == 0, do: 0, else: bsl(0xFFFFFFFF, 32 - prefix_len) |> band(0xFFFFFFFF)
        ip_int = bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d
        band(ip_int, mask) == band(base_int, mask)

      :error ->
        false
    end
  end

  # IPv4-mapped IPv6 — extract IPv4 and delegate
  defp cidr_matches?(cidr_string, {0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    import Bitwise
    cidr_matches?(cidr_string, {bsr(ab, 8), band(ab, 0xFF), bsr(cd, 8), band(cd, 0xFF)})
  end

  defp cidr_matches?(_cidr_string, {_, _, _, _, _, _, _, _}), do: false

  defp parse_cidr_v4(cidr_string) do
    import Bitwise

    case String.split(cidr_string, "/") do
      [ip_str, prefix_str] ->
        with {prefix_len, ""} <- Integer.parse(prefix_str),
             true <- prefix_len >= 0 and prefix_len <= 32,
             {:ok, {a, b, c, d}} <- :inet.parse_address(String.to_charlist(ip_str)) do
          base_int = bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d
          {:ok, base_int, prefix_len}
        else
          _ -> :error
        end

      _ ->
        :error
    end
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
          {:ok, non_neg_integer() | :unlimited} | {:error, :rate_limited, non_neg_integer()} | {:error, atom()}
  def check_rate_limit(%__MODULE__{rate_limit: nil}, _ctx, _component_ref), do: {:ok, :unlimited}

  def check_rate_limit(%__MODULE__{} = policy, %Context{user_id: user_id}, component_ref) do
    if Code.ensure_loaded?(Opus.RateLimiter) do
      apply(Opus.RateLimiter, :check, [user_id, component_ref, policy])
    else
      Logger.error("[Sanctum.Policy] Opus.RateLimiter not loaded — rate limiting is unavailable for #{component_ref}. Ensure the :opus application is started.")
      {:error, :rate_limiter_unavailable}
    end
  end

  @doc """
  Parse timeout string to milliseconds.

  ## Examples

      iex> Sanctum.Policy.timeout_ms(%Sanctum.Policy{timeout: "30s"})
      {:ok, 30_000}

      iex> Sanctum.Policy.timeout_ms(%Sanctum.Policy{timeout: "1m"})
      {:ok, 60_000}

  """
  @spec timeout_ms(t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
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

  defp tool_matches?("*", _tool_action), do: true

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

  @doc """
  Parse a duration string to milliseconds.

  Supports: "500ms", "30s", "5m", "1h", or integer seconds.

  ## Examples

      iex> Sanctum.Policy.parse_duration("30s")
      {:ok, 30_000}

      iex> Sanctum.Policy.parse_duration("5m")
      {:ok, 300_000}

  """
  @spec parse_duration(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def parse_duration(duration) when is_binary(duration) do
    cond do
      String.ends_with?(duration, "ms") ->
        parse_int_unit(duration, "ms", 1)

      String.ends_with?(duration, "s") ->
        parse_int_unit(duration, "s", 1000)

      String.ends_with?(duration, "m") ->
        parse_int_unit(duration, "m", 60 * 1000)

      String.ends_with?(duration, "h") ->
        parse_int_unit(duration, "h", 60 * 60 * 1000)

      true ->
        case Integer.parse(duration) do
          {n, ""} -> {:ok, n * 1000}
          _ -> {:error, "Invalid duration '#{duration}'. Expected format: 30s, 5m, 1h, 500ms, or integer seconds"}
        end
    end
  end

  def parse_duration(other) do
    {:error, "Invalid duration #{inspect(other)}. Expected a string like '30s', '5m', '1h', or '500ms'"}
  end

  defp parse_int_unit(str, suffix, multiplier) do
    raw = String.trim_trailing(str, suffix)

    case Integer.parse(raw) do
      {n, ""} -> {:ok, n * multiplier}
      _ -> {:error, "Invalid duration '#{str}'. Expected format: 30s, 5m, 1h, 500ms, or integer seconds"}
    end
  end

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
      "allowed_paths" => policy.allowed_paths,
      "allowed_actions" => policy.allowed_actions,
      "batch_timeout" => policy.batch_timeout,
      "max_concurrent_tasks" => policy.max_concurrent_tasks,
      "allowed_private_ips" => policy.allowed_private_ips
    }
  end

  defp format_rate_limit(nil), do: nil
  defp format_rate_limit(%{requests: req, window: win}), do: %{"requests" => req, "window" => win}

  @doc """
  Convert a map to a Policy struct.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(map) when is_map(map) do
    with {:ok, rate_limit} <- parse_rate_limit(map["rate_limit"]),
         {:ok, memory} <- parse_memory(map["max_memory_bytes"]),
         {:ok, req_size} <- parse_size(map["max_request_size"], 1_048_576),
         {:ok, resp_size} <- parse_size(map["max_response_size"], 5_242_880) do
      {:ok,
       %__MODULE__{
         allowed_domains: get_list(map, "allowed_domains"),
         allowed_methods: get_methods(map),
         rate_limit: rate_limit,
         timeout: map["timeout"] || "1m",
         max_memory_bytes: memory,
         max_request_size: req_size,
         max_response_size: resp_size,
         allowed_tools: get_list(map, "allowed_tools"),
         allowed_paths: get_list(map, "allowed_paths"),
         allowed_actions: get_actions(map),
         batch_timeout: map["batch_timeout"] || "5m",
         max_concurrent_tasks: get_integer(map, "max_concurrent_tasks", 10),
         allowed_private_ips: get_list(map, "allowed_private_ips")
       }}
    end
  end

  defp get_methods(map) do
    case Map.get(map, "allowed_methods") do
      nil -> []
      methods when is_list(methods) -> Enum.map(methods, &String.upcase/1)
      method when is_binary(method) -> [String.upcase(method)]
    end
  end

  defp get_actions(map) do
    case Map.get(map, "allowed_actions") do
      nil -> []
      actions when is_list(actions) -> Enum.map(actions, &String.downcase/1)
      action when is_binary(action) -> [String.downcase(action)]
    end
  end

  defp get_list(map, key) do
    case Map.get(map, key) do
      nil -> []
      list when is_list(list) -> list
      value when is_binary(value) -> [value]
    end
  end

  defp get_integer(map, key, default) do
    case Map.get(map, key) do
      nil -> default
      val when is_integer(val) -> val
      val when is_binary(val) ->
        case Integer.parse(val) do
          {n, ""} -> n
          _ -> default
        end
      _ -> default
    end
  end

  defp parse_rate_limit(nil), do: {:ok, nil}

  defp parse_rate_limit(value) when is_binary(value) do
    case String.split(value, "/") do
      [requests_str, window] ->
        case Integer.parse(requests_str) do
          {requests, ""} ->
            {:ok, %{requests: requests, window: window}}

          _ ->
            {:error, "Invalid rate limit '#{value}'. Expected format: '100/1m' (requests/window)"}
        end

      _ ->
        {:error, "Invalid rate limit '#{value}'. Expected format: '100/1m' (requests/window)"}
    end
  end

  defp parse_rate_limit(%{"requests" => req, "window" => win}) do
    {:ok, %{requests: req, window: win}}
  end

  defp parse_rate_limit(other) do
    {:error, "Invalid rate limit #{inspect(other)}. Expected nil, a string like '100/1m', or a map with 'requests' and 'window'"}
  end

  defp parse_memory(nil), do: {:ok, 64 * 1024 * 1024}

  defp parse_memory(bytes) when is_integer(bytes), do: {:ok, bytes}

  defp parse_memory(str) when is_binary(str) do
    result =
      cond do
        String.ends_with?(str, "MB") ->
          parse_size_int(str, "MB", 1024 * 1024)

        String.ends_with?(str, "GB") ->
          parse_size_int(str, "GB", 1024 * 1024 * 1024)

        String.ends_with?(str, "KB") ->
          parse_size_int(str, "KB", 1024)

        true ->
          case Integer.parse(str) do
            {n, ""} -> {:ok, n}
            _ -> :parse_error
          end
      end

    case result do
      {:ok, _} = ok -> ok
      :parse_error -> {:error, "Invalid memory size '#{str}'. Expected format: 64MB, 1GB, 512KB, or integer bytes"}
    end
  end

  defp parse_size(nil, default), do: {:ok, default}
  defp parse_size(bytes, _default) when is_integer(bytes), do: {:ok, bytes}
  defp parse_size(str, _default) when is_binary(str) do
    result =
      cond do
        String.ends_with?(str, "MB") ->
          parse_size_int(str, "MB", 1024 * 1024)

        String.ends_with?(str, "GB") ->
          parse_size_int(str, "GB", 1024 * 1024 * 1024)

        String.ends_with?(str, "KB") ->
          parse_size_int(str, "KB", 1024)

        true ->
          case Integer.parse(str) do
            {n, ""} -> {:ok, n}
            _ -> :parse_error
          end
      end

    case result do
      {:ok, _} = ok -> ok
      :parse_error -> {:error, "Invalid size '#{str}'. Expected format: 1MB, 1GB, 512KB, or integer bytes"}
    end
  end

  defp parse_size_int(str, suffix, multiplier) do
    raw = String.trim_trailing(str, suffix)

    case Integer.parse(raw) do
      {n, ""} -> {:ok, n * multiplier}
      _ -> :parse_error
    end
  end
end
