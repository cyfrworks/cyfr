# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Destination do
  @moduledoc """
  Where a credential's material may go: the owner's restriction on the
  account, a bound independent of the consuming component's egress grant.
  A request passes both.

  ## Shape

      %{"hosts" => ["api.openai.com", "*.googleapis.com"],
        "scheme" => "https", "port" => 443,
        "methods" => ["GET", "POST"], "paths" => ["/v1/models"]}

    * `hosts` — a non-empty list of at most 32 distinct names
      (`max_entries/0`) in the egress domain grammar: an exact
      lowercase hostname, or `*.` and a hostname of at least two labels,
      which matches every name below it and not the name itself. `*`
      alone, a scheme, a port, a path and a trailing dot are refused.
    * `scheme` — `https` unless `http` is stated.
    * `port` — 1 to 65535; absent means the scheme's default.
    * `methods` — HTTP methods from `methods/0`; absent admits any.
    * `paths` — at most 32 distinct path prefixes (`valid_path?/1`), compared
      segment by segment: `/v1/models` admits `/v1/models` and
      `/v1/models/…`, never `/v1/models-x`; absent admits any path.

  `methods` and `paths` are optional on an athanor's entry and required,
  non-empty, on an instance entry: `new/2`'s second argument says which.
  A present `methods` or `paths` is never empty.

  ## Canonical form

  `new/2` normalizes: hosts lower-cased, de-duplicated and sorted; the
  scheme lower-cased, `https` when omitted; methods upper-cased,
  de-duplicated and sorted; paths de-duplicated and sorted. `to_map/1`
  answers string keys, `hosts` and `scheme` always and `port`, `methods`
  and `paths` only when present, so `from_map(to_map(d)) == {:ok, d}`.
  `canonical/1` is the JCS of `to_map/1`, the bytes a binding digest
  covers.

  ## Paths

  A path begins with `/` and is printable ASCII without `?`, `#`, `\\` or
  `;`. It carries no encoded dot, separator or parameter mark (`%2e`,
  `%2f`, `%5c`, `%3b`), no encoded percent (`%25`, so nothing decodes
  twice) and no overlong UTF-8 lead byte (`%c0`, `%c1`), in any case, no
  `.` or `..` segment and no empty segment (a single trailing `/`
  excepted), so a prefix check cannot pass what an upstream would
  normalize outside the prefix, `/v1/models/..;/x` and
  `/v1/models/%252e%252e/x` included. `matches?/3` holds the request's path to
  the same grammar and refuses one that fails it.
  """

  @enforce_keys [:hosts, :scheme]
  defstruct [:hosts, :scheme, port: nil, methods: nil, paths: nil]

  @type t :: %__MODULE__{
          hosts: [String.t(), ...],
          scheme: String.t(),
          port: 1..65_535 | nil,
          methods: [String.t(), ...] | nil,
          paths: [String.t(), ...] | nil
        }

  @typedoc "Why a destination is refused."
  @type reason ::
          :not_a_map
          | {:unknown_key, term()}
          | :hosts_required
          | {:invalid_list, String.t()}
          | {:invalid_host, term()}
          | {:invalid_scheme, term()}
          | {:invalid_port, term()}
          | {:invalid_method, term()}
          | {:invalid_path, term()}
          | {:empty, String.t()}
          | {:too_many, String.t()}
          | {:required, String.t()}

  @type error :: {:invalid_destination, reason()}

  @keys ~w(hosts scheme port methods paths)
  @schemes ~w(http https)
  @default_ports %{"http" => 80, "https" => 443}
  @methods ~w(DELETE GET HEAD OPTIONS PATCH POST PUT)

  @label "[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?"
  @hostname Regex.compile!("\\A(?=.{1,253}\\z)#{@label}(?:\\.#{@label})*\\z")
  @wildcard_base Regex.compile!("\\A(?=.{1,253}\\z)#{@label}(?:\\.#{@label})+\\z")

  @max_path_bytes 1024
  @max_entries 32
  @path_chars ~r/\A\/[\x21-\x7E]*\z/
  @percent ~r/%(?![0-9A-Fa-f]{2})/
  @refused_escape ~r/%(2e|2f|5c|3b|25|c0|c1)/i

  @doc "The HTTP methods a destination may name, sorted."
  @spec methods() :: [String.t()]
  def methods, do: @methods

  @doc """
  How many distinct hosts, and how many distinct paths, a destination
  names at most, counted after normalization. A need's `hosts` and `paths`
  (`Prima.Manifest.Needs`) carry the same bound, so a destination
  prefilled from a need never exceeds its own.
  """
  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  @doc """
  The destination `map` spells, normalized, or why it is refused.
  `require_methods_and_paths` is true for an instance entry, whose
  destination names both.
  """
  @spec new(term(), boolean()) :: {:ok, t()} | {:error, error()}
  def new(map, require_methods_and_paths)

  def new(map, required) when is_map(map) and not is_struct(map) and is_boolean(required) do
    with :ok <- known_keys(map),
         {:ok, hosts} <- hosts(Map.get(map, "hosts")),
         {:ok, scheme} <- scheme(Map.get(map, "scheme")),
         {:ok, port} <- port(Map.get(map, "port")),
         {:ok, methods} <- optional_list(map, "methods", &method/1),
         {:ok, paths} <- optional_list(map, "paths", &path/1),
         :ok <- required(required, "methods", methods),
         :ok <- required(required, "paths", paths) do
      {:ok, %__MODULE__{hosts: hosts, scheme: scheme, port: port, methods: methods, paths: paths}}
    else
      {:error, reason} -> {:error, {:invalid_destination, reason}}
    end
  end

  def new(_map, required) when is_boolean(required),
    do: {:error, {:invalid_destination, :not_a_map}}

  @doc """
  The destination a wire map spells (`to_map/1`'s form), held to the
  athanor-entry grammar: methods and paths optional.
  """
  @spec from_map(term()) :: {:ok, t()} | {:error, error()}
  def from_map(map), do: new(map, false)

  @doc "The destination as its canonical string-keyed map."
  @spec to_map(t()) :: %{String.t() => term()}
  def to_map(%__MODULE__{} = destination) do
    %{"hosts" => destination.hosts, "scheme" => destination.scheme}
    |> put_present("port", destination.port)
    |> put_present("methods", destination.methods)
    |> put_present("paths", destination.paths)
  end

  @doc "The JCS bytes of `to_map/1`: what a binding digest covers."
  @spec canonical(t()) :: binary()
  def canonical(%__MODULE__{} = destination) do
    {:ok, bytes} = Prima.JCS.encode(to_map(destination))
    bytes
  end

  @doc """
  Whether a request to `uri` with `method` stays inside the destination:
  the scheme, the effective port, the host against `hosts`, the method
  against `methods` and the path against `paths`. A URI carrying user
  information, a host that is no string, a method outside `methods/0` or
  a path outside the path grammar never matches.
  """
  @spec matches?(t(), URI.t(), term()) :: boolean()
  def matches?(%__MODULE__{} = destination, %URI{} = uri, method) do
    with true <- is_nil(uri.userinfo),
         true <- is_binary(uri.scheme) and String.downcase(uri.scheme) == destination.scheme,
         true <- effective_port(uri, destination) == destination_port(destination),
         true <- Prima.Network.domain_allowed?(uri.host, destination.hosts),
         true <- method_admitted?(destination, method) do
      path_admitted?(destination, request_path(uri.path))
    else
      _ -> false
    end
  end

  @doc "Whether `host` is a destination host: an exact hostname or `*.` and a hostname."
  @spec valid_host?(term()) :: boolean()
  def valid_host?("*." <> base), do: Regex.match?(@wildcard_base, base)
  def valid_host?(host) when is_binary(host), do: Regex.match?(@hostname, host)
  def valid_host?(_host), do: false

  @doc """
  Whether `path` is in the path grammar the module doc names: begins with
  `/`, no encoded dot or separator, no `.`, `..` or empty segment but a
  single trailing `/`.
  """
  @spec valid_path?(term()) :: boolean()
  def valid_path?("/"), do: true

  def valid_path?("/" <> rest = path) when byte_size(path) <= @max_path_bytes do
    Regex.match?(@path_chars, path) and not String.contains?(path, ["?", "#", "\\", ";"]) and
      not Regex.match?(@percent, path) and not Regex.match?(@refused_escape, path) and
      segments_valid?(String.split(rest, "/"))
  end

  def valid_path?(_path), do: false

  # ---------------------------------------------------------------------------
  # Matching
  # ---------------------------------------------------------------------------

  defp effective_port(%URI{port: port}, _destination) when is_integer(port), do: port
  defp effective_port(%URI{}, destination), do: destination_port(%{destination | port: nil})

  defp destination_port(%__MODULE__{port: port}) when is_integer(port), do: port
  defp destination_port(%__MODULE__{scheme: scheme}), do: Map.fetch!(@default_ports, scheme)

  defp method_admitted?(%__MODULE__{methods: methods}, method) when is_binary(method) do
    method = String.upcase(method)
    method in @methods and (methods == nil or method in methods)
  end

  defp method_admitted?(_destination, _method), do: false

  defp request_path(nil), do: "/"
  defp request_path(""), do: "/"
  defp request_path(path), do: path

  defp path_admitted?(%__MODULE__{paths: paths}, path) do
    valid_path?(path) and
      (paths == nil or Enum.any?(paths, &List.starts_with?(segments(path), segments(&1))))
  end

  # A path's segments, the trailing `/`'s empty one dropped: the root is
  # no segment at all, so it admits every path.
  defp segments(path) do
    path
    |> String.trim_leading("/")
    |> String.split("/")
    |> Enum.reject(&(&1 == ""))
  end

  defp segments_valid?(segments) do
    {last, init} = List.pop_at(segments, -1)
    Enum.all?(init, &segment?/1) and (last == "" or segment?(last))
  end

  defp segment?(segment), do: segment not in ["", ".", ".."]

  # ---------------------------------------------------------------------------
  # Reading
  # ---------------------------------------------------------------------------

  defp known_keys(map) do
    case map |> Map.keys() |> Enum.reject(&(&1 in @keys)) |> Enum.sort() do
      [] -> :ok
      [key | _rest] -> {:error, {:unknown_key, key}}
    end
  end

  defp hosts(nil), do: {:error, :hosts_required}
  defp hosts([]), do: {:error, :hosts_required}

  defp hosts(list) when is_list(list) do
    with {:ok, hosts} <- each(list, "hosts", &host/1), do: bounded("hosts", set(hosts))
  end

  defp hosts(_other), do: {:error, {:invalid_list, "hosts"}}

  defp host(host) when is_binary(host) do
    lowered = String.downcase(host)
    if valid_host?(lowered), do: {:ok, lowered}, else: {:error, {:invalid_host, host}}
  end

  defp host(host), do: {:error, {:invalid_host, host}}

  defp scheme(nil), do: {:ok, "https"}

  defp scheme(scheme) when is_binary(scheme) do
    lowered = String.downcase(scheme)
    if lowered in @schemes, do: {:ok, lowered}, else: {:error, {:invalid_scheme, scheme}}
  end

  defp scheme(scheme), do: {:error, {:invalid_scheme, scheme}}

  defp port(nil), do: {:ok, nil}
  defp port(port) when is_integer(port) and port in 1..65_535, do: {:ok, port}
  defp port(port), do: {:error, {:invalid_port, port}}

  defp method(method) when is_binary(method) do
    upper = String.upcase(method)
    if upper in @methods, do: {:ok, upper}, else: {:error, {:invalid_method, method}}
  end

  defp method(method), do: {:error, {:invalid_method, method}}

  defp path(path) do
    if valid_path?(path), do: {:ok, path}, else: {:error, {:invalid_path, path}}
  end

  defp optional_list(map, field, read) do
    case Map.get(map, field) do
      nil ->
        {:ok, nil}

      [] ->
        {:error, {:empty, field}}

      list when is_list(list) ->
        with {:ok, read} <- each(list, field, read), do: bounded(field, set(read))

      _other ->
        {:error, {:invalid_list, field}}
    end
  end

  defp each(list, _field, read) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case read.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp bounded(field, list) when length(list) > @max_entries, do: {:error, {:too_many, field}}
  defp bounded(_field, list), do: {:ok, list}

  defp required(true, field, nil), do: {:error, {:required, field}}
  defp required(_required, _field, _value), do: :ok

  defp set(list), do: list |> Enum.uniq() |> Enum.sort()

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
