# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Policy do
  @moduledoc """
  Host Policy configuration for CYFR.

  Policies define what components are allowed to do at runtime. Opus enforces
  these policies—components never see them.

  ## Policy Storage

  Policies are stored via `Sanctum.PolicyStore`. When no policy
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
  alias Sanctum.Policy.Enforcement

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
          allowed_private_ips: [String.t()],
          is_public: boolean()
        }

  # Canonical default resource limits — shared by every default-policy
  # builder, the struct defaults, and the JSON parse fallbacks.
  @default_max_memory_bytes 64 * 1024 * 1024
  @default_max_request_size 1_048_576

  @type_defaults %{
    catalyst: %{
      allowed_domains: [],
      allowed_methods: [],
      rate_limit: %{requests: 100, window: "1m"},
      timeout: "3m",
      max_memory_bytes: @default_max_memory_bytes,
      max_request_size: @default_max_request_size,
      max_response_size: 5_242_880,
      allowed_tools: [],
      allowed_paths: [],
      allowed_actions: [],
      batch_timeout: "5m",
      max_concurrent_tasks: 10,
      allowed_private_ips: [],
      is_public: false
    },
    formula: %{
      allowed_domains: [],
      allowed_methods: [],
      rate_limit: %{requests: 100, window: "1m"},
      timeout: "5m",
      max_memory_bytes: @default_max_memory_bytes,
      max_request_size: @default_max_request_size,
      max_response_size: 5_242_880,
      allowed_tools: [],
      allowed_paths: [],
      batch_timeout: "5m",
      max_concurrent_tasks: 10,
      allowed_private_ips: [],
      is_public: false
    },
    reagent: %{
      allowed_domains: [],
      allowed_methods: [],
      rate_limit: %{requests: 100, window: "1m"},
      timeout: "1m",
      max_memory_bytes: @default_max_memory_bytes,
      max_request_size: @default_max_request_size,
      max_response_size: 5_242_880,
      allowed_tools: [],
      allowed_paths: [],
      batch_timeout: "5m",
      max_concurrent_tasks: 10,
      allowed_private_ips: [],
      is_public: false
    },
    tincture: %{
      rate_limit: %{requests: 100, window: "1m"},
      is_public: false
    }
  }

  defstruct allowed_domains: [],
            allowed_methods: [],
            rate_limit: nil,
            timeout: "1m",
            max_memory_bytes: @default_max_memory_bytes,
            # 1MB default
            max_request_size: @default_max_request_size,
            # 5MB default
            max_response_size: 5_242_880,
            # deny-by-default for MCP tools
            allowed_tools: [],
            # "data/" (prefix), "data/file.json" (exact), or "*" (all). empty = deny all
            allowed_paths: [],
            # storage actions: read, write, list, delete, exists. empty = deny all
            allowed_actions: [],
            # max time for await-all/await-any
            batch_timeout: "5m",
            # max spawned tasks per formula execution
            max_concurrent_tasks: 10,
            # private IPs/CIDRs allowed (empty = deny all)
            allowed_private_ips: [],
            # tincture visibility (only used for tincture type)
            is_public: false

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Get the effective policy for a component reference.

  Looks up the policy from SQLite via PolicyStore. If no policy exists,
  returns the default (deny-all for domains).

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> {:ok, policy} = Sanctum.Policy.get_effective(ctx, "stripe-catalyst")
      iex> policy.allowed_domains
      ["api.stripe.com"]

  """
  @spec get_effective(Context.t(), String.t(), keyword()) ::
          {:ok, t(), map()} | {:error, term()}
  def get_effective(%Context{} = ctx, component_ref, opts \\ [])
      when is_binary(component_ref) do
    Sanctum.Policy.Resolver.get_effective(ctx, component_ref, opts)
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
      max_memory_bytes: @default_max_memory_bytes,
      # 1MB
      max_request_size: @default_max_request_size,
      # 5MB
      max_response_size: 5_242_880,
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
  def default(component_type) when component_type in [:catalyst, :formula, :reagent, :tincture] do
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
      "*" ->
        true

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
    # Always block link-local / cloud metadata (169.254.0.0/16, fe80::/10)
    if Sanctum.Cidr.link_local?(ip_tuple) do
      false
    else
      ip_string = :inet.ntoa(ip_tuple) |> to_string()

      Enum.any?(entries, fn entry ->
        ip_entry_matches?(entry, ip_tuple, ip_string)
      end)
    end
  end

  # Exact-IP match keeps the canonical-ntoa string comparison unchanged; the
  # CIDR arithmetic is delegated to the Sanctum.Cidr SSOT (which, unlike the
  # prior IPv4-only copy here, also matches IPv6 CIDR entries).
  defp ip_entry_matches?(entry, ip_tuple, ip_string) do
    if String.contains?(entry, "/") do
      Sanctum.Cidr.ip_in_cidr?(ip_tuple, entry)
    else
      entry == ip_string
    end
  end

  @doc """
  Check if an operation is within rate limits.

  Returns `{:ok, remaining}` if allowed, `{:error, :rate_limited, retry_after_ms}` if exceeded.

  Delegates to `Opus.RateLimiter` for stateful sliding window rate limiting.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> policy = %Sanctum.Policy{rate_limit: %{requests: 100, window: "1m"}}
      iex> {:ok, remaining} = Sanctum.Policy.check_rate_limit(policy, ctx, "my-component")
      iex> is_integer(remaining) or remaining == :unlimited
      true

  """
  @spec check_rate_limit(t(), Context.t(), String.t()) ::
          {:ok, non_neg_integer() | :unlimited}
          | {:error, :rate_limited, non_neg_integer()}
          | {:error, atom()}
  def check_rate_limit(%__MODULE__{rate_limit: nil}, _ctx, _component_ref), do: {:ok, :unlimited}

  def check_rate_limit(%__MODULE__{} = policy, %Context{} = ctx, component_ref) do
    result =
      if Code.ensure_loaded?(Opus.RateLimiter) do
        # Normalize so a not-yet-resolved org/project never reaches the limiter as
        # "" (rejected as :missing_tenant). Rate limits are scoped per org+project
        # — members of a project share the budget. A resolved context already
        # carries concrete coords; this is defense-in-depth.
        org_id = Arca.QueryHelpers.normalize_org_id(ctx.org_id)
        project_id = Arca.QueryHelpers.normalize_project_id(ctx.project_id)

        try do
          apply(Opus.RateLimiter, :check, [org_id, project_id, component_ref, policy])
        catch
          # Module loaded but the limiter process isn't running (or timed out).
          # Same fail-closed deny as the not-loaded branch below — a dead
          # limiter must surface as a rate-limit rejection, not a crash/500.
          :exit, reason ->
            Logger.error(
              "[Sanctum.Policy] Opus.RateLimiter unavailable (#{inspect(reason)}) — " <>
                "failing CLOSED (denying) for #{component_ref}."
            )

            {:error, :rate_limited}
        end
      else
        Logger.error(
          "[Sanctum.Policy] Opus.RateLimiter not loaded — failing CLOSED (denying) for " <>
            "#{component_ref}. A configured rate limit must be enforceable; an unavailable " <>
            "limiter must not silently allow unbounded requests. Ensure :opus is started."
        )

        # Fail closed. Return the same deny signal as an exceeded limit so
        # every caller's existing rate-limit-denied handling rejects the
        # request, rather than a distinct error a caller might treat as "allow".
        {:error, :rate_limited}
      end

    # Audit denials here — the single chokepoint every rate-limited surface
    # (executor, tincture invoke, shell preview, MCP policy tool) goes through.
    # Recording after the try/catch keeps the audit write's own failures out of
    # the fail-closed exit handling above.
    case result do
      {:error, :rate_limited, retry_ms} ->
        record_rate_limit_denial(ctx, component_ref, "rate limit exceeded (retry in #{retry_ms}ms)")

      {:error, :rate_limited} ->
        record_rate_limit_denial(ctx, component_ref, "rate limiter unavailable (fail closed)")

      _ ->
        :ok
    end

    result
  end

  defp record_rate_limit_denial(%Context{} = ctx, component_ref, reason) do
    Enforcement.record(%{
      ctx: ctx,
      component_ref: component_ref,
      event_type: :rate_limit,
      decision: :denied,
      decision_reason: reason
    })
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
          {n, ""} ->
            {:ok, n * 1000}

          _ ->
            {:error,
             "Invalid duration '#{duration}'. Expected format: 30s, 5m, 1h, 500ms, or integer seconds"}
        end
    end
  end

  def parse_duration(other) do
    {:error,
     "Invalid duration #{inspect(other)}. Expected a string like '30s', '5m', '1h', or '500ms'"}
  end

  defp parse_int_unit(str, suffix, multiplier) do
    raw = String.trim_trailing(str, suffix)

    case Integer.parse(raw) do
      {n, ""} ->
        {:ok, n * multiplier}

      _ ->
        {:error,
         "Invalid duration '#{str}'. Expected format: 30s, 5m, 1h, 500ms, or integer seconds"}
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
      "allowed_private_ips" => policy.allowed_private_ips,
      "is_public" => policy.is_public
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
         {:ok, req_size} <- parse_size(map["max_request_size"], @default_max_request_size),
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
         allowed_private_ips: get_list(map, "allowed_private_ips"),
         is_public: map["is_public"] == true
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
      nil ->
        default

      val when is_integer(val) ->
        val

      val when is_binary(val) ->
        case Integer.parse(val) do
          {n, ""} -> n
          _ -> default
        end

      _ ->
        default
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
    {:error,
     "Invalid rate limit #{inspect(other)}. Expected nil, a string like '100/1m', or a map with 'requests' and 'window'"}
  end

  defp parse_memory(nil), do: {:ok, @default_max_memory_bytes}

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
      {:ok, _} = ok ->
        ok

      :parse_error ->
        {:error,
         "Invalid memory size '#{str}'. Expected format: 64MB, 1GB, 512KB, or integer bytes"}
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
      {:ok, _} = ok ->
        ok

      :parse_error ->
        {:error, "Invalid size '#{str}'. Expected format: 1MB, 1GB, 512KB, or integer bytes"}
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
