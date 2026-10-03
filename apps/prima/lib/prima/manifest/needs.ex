# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Manifest.Needs do
  @moduledoc """
  The manifest `needs` block: named roles a component asks the operator
  to satisfy with vault entries.

  Two vocabularies meet only at consent — the developer names *roles*
  (`source`, `dest`, `api_key`); the operator names *credentials*;
  consent maps them. A component never writes or learns a vault entry
  name.

  ## Shape

      "needs": {
        "api_key": { "type": "api_key:anthropic.com",
                     "reason": "to call the Anthropic API with your key",
                     "fields": ["ANTHROPIC_API_KEY"], "required": true }
      }

  The need name is the slot key (`ref|need` in blob edge keys), so the
  edge-key grammar constrains it: lowercase, no `@` prefix, no `|`.
  `type` is `kind:qualifier` — a credential kind (`api_key`, `oauth`,
  `bundle`) or a component type for component-typed needs. `reason` is
  the prose the operator sees instead of the developer's key names.
  `fields` are the guest-visible read keys, served from the bound entry's
  material as the projection — the names the binary already passes to
  `cyfr:vault/read.get`, so no interface changes. `scopes` applies to
  OAuth kinds only.

  ## Attaching and disclosing

  A credential need may declare, beside those:

    * `attach` — how the control plane attaches the value to a request
      the component names this need on: `{"in": "header" | "query",
      "name": ..., "template": ...}` (`t:attach/0`). The template holds
      `{value}` exactly once; a header's name is an RFC 9110 token, a
      query key unreserved URI characters, and a header is none of the
      headers that route or frame a request
      (`Prima.Network.framing_headers/0`) or override its method or
      target or claim a forwarded origin
      (`Prima.Network.override_headers/0`). An `oauth` need's `attach`
      that omits `template` takes `Authorization: Bearer {value}`.
    * `hosts` and `paths` — the destination the need speaks to, in
      `Prima.Destination`'s host and path grammar and at most
      `Prima.Destination.max_entries/0` distinct entries each, as a
      destination names; a surface prefills a new entry's destination
      from them. `Prima.Manifest.Caps` holds the
      hosts within the manifest's egress domains.
    * `disclose` — `true` when the component must hold the material
      itself (`cyfr:vault/read`, `cyfr:oauth/token`); `false` by default.

  **A need that declares no `attach` is disclose-only**, OAuth included,
  and is satisfied by a disclosed entry alone: the shape of every catalyst
  published before attaching existed, valid under this grammar, and
  nothing opts such a need into attachment. A need may both attach and
  disclose. A component-typed need names a dependency, not a credential,
  and refuses all four.
  """

  @name_re ~r/^[a-z][a-z0-9_-]{0,31}$/
  @type_re ~r/^[a-z_]+:[a-z0-9._-]+$/
  # Needs accept credential kinds and the executable types defined by
  # Prima.ComponentRef.
  @credential_kinds ~w(api_key oauth bundle)
  @kinds @credential_kinds ++ Prima.ComponentRef.executable_types()
  @credential_only_keys ~w(attach hosts paths disclose)
  @entry_keys ~w(type reason fields scopes required) ++ @credential_only_keys

  @attach_ins ~w(header query)
  @placeholder "{value}"
  @max_template_bytes 1024
  # RFC 9110 `token`: a header name.
  @token ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]{1,256}\z/
  # RFC 3986 unreserved characters: a query key that needs no encoding.
  @query_key ~r/\A[A-Za-z0-9._~-]{1,256}\z/
  @bearer %{in: "header", name: "Authorization", template: "Bearer {value}"}

  @typedoc """
  An attach rule: where the value goes in a request, under which name,
  and the template it is rendered into, `{value}` exactly once.
  """
  @type attach :: %{in: String.t(), name: String.t(), template: String.t()}

  @type error :: {:invalid_needs, term()}

  @doc """
  Validate a decoded manifest's `needs` block. Absent is valid.
  """
  @spec validate(map() | nil) :: :ok | {:error, error()}
  def validate(nil), do: :ok

  def validate(%{"needs" => needs}) when is_map(needs) do
    Enum.reduce_while(needs, :ok, fn {name, entry}, :ok ->
      case validate_need(name, entry) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def validate(%{"needs" => other}), do: {:error, {:invalid_needs, {:not_a_map, other}}}
  def validate(manifest) when is_map(manifest), do: :ok

  @doc """
  The normalized needs for a decoded manifest: a sorted list of
  `%{name, kind, qualifier, reason, fields, scopes, required, attach,
  hosts, paths, disclose}`, `attach` the need's rule (`t:attach/0`) or
  nil for a disclose-only need, and `hosts` and `paths` de-duplicated
  and sorted. Returns `nil` when the manifest
  declares no `needs` block.
  """
  @spec from_manifest(map() | nil) :: [map()] | nil
  def from_manifest(%{"needs" => needs} = manifest) when is_map(needs) do
    case validate(manifest) do
      :ok ->
        needs
        |> Enum.map(fn {name, entry} ->
          [kind, qualifier] = String.split(entry["type"], ":", parts: 2)
          {:ok, attach} = attach_of(name, kind, entry)

          %{
            name: name,
            kind: kind,
            qualifier: qualifier,
            reason: entry["reason"],
            fields: Enum.sort(entry["fields"] || []),
            scopes: Enum.sort(entry["scopes"] || []),
            required: Map.get(entry, "required", true),
            attach: attach,
            hosts: set(entry["hosts"] || []),
            paths: set(entry["paths"] || []),
            disclose: Map.get(entry, "disclose", false)
          }
        end)
        |> Enum.sort_by(& &1.name)

      {:error, _} ->
        nil
    end
  end

  def from_manifest(_manifest), do: nil

  @doc """
  Whether a normalized need (`from_manifest/1`'s) is disclose-only: it
  declares no attach rule, so only a disclosed entry satisfies it.
  """
  @spec disclose_only?(map()) :: boolean()
  def disclose_only?(%{attach: nil}), do: true
  def disclose_only?(%{attach: %{}}), do: false

  @doc """
  An attach rule from its wire map, `%{"in", "name", "template"}`, every
  member present (no default applies on the wire), or why it is refused.
  """
  @spec read_attach(term()) :: {:ok, attach()} | {:error, term()}
  def read_attach(%{"in" => _, "name" => _, "template" => _} = raw) when map_size(raw) == 3,
    do: check_attach(%{in: raw["in"], name: raw["name"], template: raw["template"]})

  def read_attach(_raw), do: {:error, :malformed_attach}

  @doc "An attach rule as its wire map."
  @spec attach_to_map(attach()) :: %{String.t() => String.t()}
  def attach_to_map(%{in: where, name: name, template: template}),
    do: %{"in" => where, "name" => name, "template" => template}

  @doc """
  The value an attach rule carries for `value`: the template with its one
  `{value}` replaced. The one renderer of a rule; nothing concatenates a
  credential into a header or a query elsewhere.
  """
  @spec render_attach(attach(), String.t()) :: String.t()
  def render_attach(%{template: template}, value) when is_binary(value) do
    [before, rest] = String.split(template, @placeholder, parts: 2)
    before <> value <> rest
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp validate_need(name, entry) do
    cond do
      not is_binary(name) or not Regex.match?(@name_re, name) ->
        {:error, {:invalid_needs, {:invalid_name, name}}}

      not is_map(entry) ->
        {:error, {:invalid_needs, {:not_a_map, name}}}

      true ->
        with :ok <- only_keys(entry, name),
             :ok <- validate_type(name, entry["type"]),
             :ok <- validate_reason(name, entry["reason"]),
             :ok <- validate_names(name, :fields, entry["fields"]),
             :ok <- validate_scopes(name, entry),
             :ok <- validate_required(name, entry),
             :ok <- credential_only(name, entry),
             {:ok, _attach} <- attach_of(name, kind_of(entry), entry),
             :ok <- validate_hosts(name, entry["hosts"]),
             :ok <- validate_paths(name, entry["paths"]),
             :ok <- validate_disclose(name, entry) do
          :ok
        end
    end
  end

  defp kind_of(entry), do: entry["type"] |> String.split(":", parts: 2) |> hd()

  # A component-typed need names a dependency to invoke, not a credential:
  # nothing is attached to its requests or disclosed to it.
  defp credential_only(name, entry) do
    if kind_of(entry) in @credential_kinds do
      :ok
    else
      case Enum.filter(@credential_only_keys, &Map.has_key?(entry, &1)) do
        [] -> :ok
        keys -> {:error, {:invalid_needs, {:not_a_credential, name, keys}}}
      end
    end
  end

  # The rule a need's `attach` spells: nil when it declares none, and for
  # an `oauth` need whose rule names no template, the bearer header.
  defp attach_of(_name, _kind, entry) when not is_map_key(entry, "attach"), do: {:ok, nil}
  defp attach_of(_name, _kind, %{"attach" => nil}), do: {:ok, nil}

  defp attach_of(name, kind, %{"attach" => raw}) when is_map(raw) do
    with :ok <- attach_keys(name, raw),
         {:ok, rule} <- attach_rule(kind, raw),
         {:ok, rule} <- check_attach(rule) do
      {:ok, rule}
    else
      {:error, {:invalid_needs, _}} = error -> error
      {:error, reason} -> {:error, {:invalid_needs, {:invalid_attach, name, reason}}}
    end
  end

  defp attach_of(name, _kind, _entry),
    do: {:error, {:invalid_needs, {:invalid_attach, name, :malformed_attach}}}

  defp attach_keys(name, raw) do
    case Map.keys(raw) -- ["in", "name", "template"] do
      [] -> :ok
      unknown -> {:error, {:invalid_needs, {:invalid_attach, name, {:unknown_keys, unknown}}}}
    end
  end

  # Only an `oauth` need's template defaults, and only to the bearer
  # header, so a rule that names another place keeps its own template.
  defp attach_rule("oauth", raw) when not is_map_key(raw, "template") do
    if Map.get(raw, "in", @bearer.in) == @bearer.in and
         Map.get(raw, "name", @bearer.name) == @bearer.name,
       do: {:ok, @bearer},
       else: {:error, :template_required}
  end

  defp attach_rule(_kind, %{"in" => where, "name" => name, "template" => template}),
    do: {:ok, %{in: where, name: name, template: template}}

  defp attach_rule(_kind, _raw), do: {:error, :malformed_attach}

  defp check_attach(%{in: where, name: name, template: template} = rule) do
    cond do
      where not in @attach_ins -> {:error, {:invalid_in, where}}
      not valid_attach_name?(where, name) -> {:error, {:invalid_name, name}}
      reserved_header?(where, name) -> {:error, {:reserved_header, name}}
      not valid_template?(template) -> {:error, {:invalid_template, template}}
      true -> {:ok, rule}
    end
  end

  defp valid_attach_name?("header", name) when is_binary(name), do: Regex.match?(@token, name)
  defp valid_attach_name?("query", name) when is_binary(name), do: Regex.match?(@query_key, name)
  defp valid_attach_name?(_where, _name), do: false

  # The headers that route or frame a request are the client's to set, and
  # one that overrides its method or target would take it outside its
  # destination.
  defp reserved_header?("header", name) do
    name = String.downcase(name)
    name in Prima.Network.framing_headers() or name in Prima.Network.override_headers()
  end

  defp reserved_header?(_where, _name), do: false

  # `{value}` exactly once, and nothing a header or a query would read as
  # its end: no control character.
  defp valid_template?(template) when is_binary(template) do
    byte_size(template) <= @max_template_bytes and String.valid?(template) and
      not String.match?(template, ~r/[\x00-\x1F\x7F]/) and
      length(String.split(template, @placeholder)) == 2
  end

  defp valid_template?(_template), do: false

  defp validate_hosts(_name, nil), do: :ok

  # The index of the first member the grammar refuses, never the member
  # itself: a nil member is refused as itself, not read as "none refused".
  defp validate_hosts(name, hosts) when is_list(hosts) and hosts != [] do
    case Enum.find_index(hosts, &(not (is_binary(&1) and Prima.Destination.valid_host?(&1)))) do
      nil -> bounded(name, :hosts, hosts)
      index -> {:error, {:invalid_needs, {:invalid_host, name, Enum.at(hosts, index)}}}
    end
  end

  defp validate_hosts(name, _hosts), do: {:error, {:invalid_needs, {:invalid_list, name, :hosts}}}

  defp validate_paths(_name, nil), do: :ok

  defp validate_paths(name, paths) when is_list(paths) and paths != [] do
    case Enum.find_index(paths, &(not (is_binary(&1) and Prima.Destination.valid_path?(&1)))) do
      nil -> bounded(name, :paths, paths)
      index -> {:error, {:invalid_needs, {:invalid_path, name, Enum.at(paths, index)}}}
    end
  end

  defp validate_paths(name, _paths), do: {:error, {:invalid_needs, {:invalid_list, name, :paths}}}

  # A destination's own bound (`Prima.Destination.max_entries/0`), counted
  # over the distinct entries `from_manifest/1` reads.
  defp bounded(name, key, list) do
    if length(set(list)) > Prima.Destination.max_entries(),
      do: {:error, {:invalid_needs, {:too_many, name, key}}},
      else: :ok
  end

  defp validate_disclose(name, entry) do
    case Map.get(entry, "disclose", false) do
      value when is_boolean(value) -> :ok
      other -> {:error, {:invalid_needs, {:invalid_disclose, name, other}}}
    end
  end

  defp set(list), do: list |> Enum.uniq() |> Enum.sort()

  defp only_keys(entry, name) do
    case Map.keys(entry) -- @entry_keys do
      [] -> :ok
      unknown -> {:error, {:invalid_needs, {:unknown_keys, name, Enum.sort(unknown)}}}
    end
  end

  defp validate_type(name, type) do
    with true <- is_binary(type),
         true <- Regex.match?(@type_re, type),
         [kind, _qualifier] <- String.split(type, ":", parts: 2),
         true <- kind in @kinds do
      :ok
    else
      _ -> {:error, {:invalid_needs, {:invalid_type, name, type}}}
    end
  end

  defp validate_reason(name, reason) do
    if is_binary(reason) and String.trim(reason) != "",
      do: :ok,
      else: {:error, {:invalid_needs, {:reason_required, name}}}
  end

  defp validate_names(_name, _key, nil), do: :ok

  defp validate_names(name, key, list) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, {:invalid_needs, {:invalid_list, name, key}}}
  end

  defp validate_names(name, key, _other),
    do: {:error, {:invalid_needs, {:invalid_list, name, key}}}

  defp validate_scopes(name, entry) do
    case entry["scopes"] do
      nil ->
        :ok

      scopes ->
        with :ok <- validate_names(name, :scopes, scopes) do
          if String.starts_with?(entry["type"] || "", "oauth:"),
            do: :ok,
            else: {:error, {:invalid_needs, {:scopes_on_non_oauth, name}}}
        end
    end
  end

  defp validate_required(name, entry) do
    case Map.get(entry, "required", true) do
      value when is_boolean(value) -> :ok
      other -> {:error, {:invalid_needs, {:invalid_required, name, other}}}
    end
  end
end
