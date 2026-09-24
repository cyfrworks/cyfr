# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Manifest do
  @moduledoc """
  The component manifest: decoding a stored value, the closed top-level
  key roster, the declared contracts, and the one validator every write
  boundary runs.

  `decode/1` and `decode_strict/1` normalize a manifest from its storage
  representations (nil, JSON string, map) into a map. `validate/2` holds a
  decoded manifest to the schema; the `needs` and `caps` blocks are
  `Cyfr.Manifest.Needs` and `Cyfr.Manifest.Caps`. Which storage paths a
  guest may name is the storage boundary's fact, so the validator takes
  that predicate as an argument (`Arca.Storage.valid_guest_path?/1` at
  every caller) and restates nothing about the layout.
  """

  alias Cyfr.Manifest.{Caps, Needs}

  # The closed top-level key roster — every field a manifest may carry,
  # which is also the roster component-guide.md documents. Identity fields
  # are validated against the directory at registration; presentational
  # fields are free text; `needs`/`caps` delegate to their owners.
  @known_keys ~w(
    name type version publisher
    description license tags category
    needs caps dependencies tincture
    schema examples defaults forked_from
    contracts agent
  )

  # A contract is `<family>/<name>@<major>`: the operations a component
  # answers on its one export, named so a host can ask for them by name
  # (`model/chat@1`).
  @contract_pattern ~r/\A[a-z][a-z0-9-]*\/[a-z][a-z0-9-]*@[1-9][0-9]*\z/

  @typedoc """
  One refusal: the block's tag and its detail. The block validators speak
  in sentences; `needs` and `caps` in their own terms
  (`t:Cyfr.Manifest.Needs.error/0`, `t:Cyfr.Manifest.Caps.error/0`).
  """
  @type failure :: {atom(), term()}

  @typedoc "What `validate/2` refuses with: the first failure, in the refusal order."
  @type error :: {:invalid_manifest, [failure(), ...]}

  @doc "The closed top-level manifest key roster (docs derive from this)."
  @spec known_keys() :: [String.t()]
  def known_keys, do: @known_keys

  @doc """
  The contracts a manifest declares (`"contracts": ["model/chat@1"]`), as
  written; an absent or malformed block declares none.
  """
  @spec contracts(term()) :: [String.t()]
  def contracts(%{"contracts" => list}) when is_list(list),
    do: Enum.filter(list, &(is_binary(&1) and Regex.match?(@contract_pattern, &1)))

  def contracts(_), do: []

  @doc """
  Validate a decoded manifest at a write boundary — the ONE manifest
  validator, called by every ingress (directory registration,
  `publish_bytes`, tincture publish, a write to a component's manifest
  file; OCI store lands through those). `storage_path_ok?` decides
  whether a `caps.storage.paths` entry names a guest scope.

  The refusals, in order; the first one found is the answer:

      * unknown top-level keys;
      * malformed `needs` or `caps` blocks;
      * malformed `tincture`, `contracts` or `agent` blocks;
      * a malformed `dependencies` block, which feeds activation-graph and
        release-digest validation.

  A value that is not a map declares nothing and passes; decoding is
  `decode_strict/1`'s.
  """
  @spec validate(term(), Caps.storage_path_check()) :: :ok | {:error, error()}
  def validate(manifest, storage_path_ok?)
      when is_map(manifest) and is_function(storage_path_ok?, 1) do
    with :ok <- reject_unknown_keys(manifest),
         :ok <- Needs.validate(manifest),
         :ok <- Caps.validate(manifest, storage_path_ok?),
         :ok <- validate_tincture_block(manifest),
         :ok <- validate_contracts_block(manifest),
         :ok <- validate_agent_block(manifest),
         :ok <- validate_dependencies_block(manifest) do
      :ok
    else
      {:error, {tag, detail}} -> {:error, {:invalid_manifest, [{tag, detail}]}}
    end
  end

  def validate(_manifest, storage_path_ok?) when is_function(storage_path_ok?, 1), do: :ok

  @doc """
  Whether a `tincture.connect` entry is a bare domain with an optional
  `*.` prefix — the grammar the served page's CSP `connect-src` is built
  from. Rejects a wildcard without a domain, IP addresses, paths, ports,
  schemes, and characters outside the domain grammar.
  """
  @spec valid_connect_domain?(term()) :: boolean()
  def valid_connect_domain?(domain) when is_binary(domain) do
    base = String.replace_prefix(domain, "*.", "")

    cond do
      domain == "*" -> false
      String.contains?(domain, "/") -> false
      String.contains?(domain, ":") -> false
      String.contains?(domain, " ") -> false
      not Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\z/, base) -> false
      true -> true
    end
  end

  def valid_connect_domain?(_), do: false

  @doc """
  Decode a manifest value into a map.

  Handles nil (returns empty map), maps (passthrough), and JSON strings.
  Returns an empty map on decode failure — a malformed manifest degrades to
  "no declarations". A caller for which that is a capability gap reads
  `decode_strict/1` instead and says so in its own log.
  """
  @spec decode(nil | map() | binary()) :: map()
  def decode(manifest) do
    case decode_strict(manifest) do
      {:ok, map} -> map
      {:error, :malformed_manifest} -> %{}
    end
  end

  @doc """
  Strict counterpart of `decode/1` for write boundaries.

  Registration must never accept a manifest it cannot parse — a malformed
  manifest would otherwise register a component with zero declared
  capabilities and skip all manifest validation. Reads of historical rows
  keep using the lenient `decode/1`.
  """
  @spec decode_strict(nil | map() | binary()) :: {:ok, map()} | {:error, :malformed_manifest}
  def decode_strict(nil), do: {:ok, %{}}
  def decode_strict(manifest) when is_map(manifest), do: {:ok, manifest}

  def decode_strict(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :malformed_manifest}
    end
  end

  def decode_strict(_), do: {:error, :malformed_manifest}

  defp reject_unknown_keys(manifest) do
    case manifest |> Map.keys() |> Enum.filter(&(is_binary(&1) and &1 not in @known_keys)) do
      [] ->
        :ok

      keys ->
        {:error,
         {:unknown_manifest_keys,
          "Manifest declares unknown top-level key(s): #{Enum.join(Enum.sort(keys), ", ")}. " <>
            "Known keys: #{Enum.join(@known_keys, ", ")}"}}
    end
  end

  defp validate_contracts_block(%{"contracts" => list}) when is_list(list) do
    case Enum.reject(list, &(is_binary(&1) and Regex.match?(@contract_pattern, &1))) do
      [] ->
        :ok

      bad ->
        {:error,
         {:invalid_contracts,
          "Manifest declares contract(s) that are not family/name@major: " <>
            Enum.map_join(bad, ", ", &inspect/1)}}
    end
  end

  defp validate_contracts_block(%{"contracts" => other}) do
    {:error, {:invalid_contracts, "Manifest `contracts` must be a list, got: #{inspect(other)}"}}
  end

  defp validate_contracts_block(_), do: :ok

  # The `agent` block is the projected consent shape of an AQUA agent:
  # catalyst, model, and the auto/ask policy sets. It is refused on every
  # other type.
  defp validate_agent_block(%{"type" => "agent", "agent" => agent}),
    do: validate_agent_value(agent)

  defp validate_agent_block(%{"agent" => _}) do
    {:error, {:invalid_agent, "agent is only valid on type agent"}}
  end

  defp validate_agent_block(_), do: :ok

  defp validate_agent_value(agent) when is_map(agent) do
    extras =
      agent
      |> Map.keys()
      |> Enum.filter(&(is_binary(&1) and &1 not in ~w(catalyst model policy)))

    cond do
      extras != [] ->
        {:error, {:invalid_agent, "unknown key(s): #{Enum.join(Enum.sort(extras), ", ")}"}}

      not valid_agent_catalyst?(agent["catalyst"]) ->
        {:error, {:invalid_agent, "agent.catalyst must be a name-level component ref"}}

      not valid_agent_model?(agent["model"]) ->
        {:error, {:invalid_agent, "agent.model must be a non-empty string"}}

      true ->
        validate_agent_policy(agent["policy"])
    end
  end

  defp validate_agent_value(other) do
    {:error, {:invalid_agent, "agent must be an object, got: #{inspect(other)}"}}
  end

  defp valid_agent_catalyst?(nil), do: true

  defp valid_agent_catalyst?(ref) when is_binary(ref) and ref != "" do
    match?({:ok, %{version: nil}}, Cyfr.ComponentRef.parse(ref))
  end

  defp valid_agent_catalyst?(_), do: false

  defp valid_agent_model?(nil), do: true
  defp valid_agent_model?(model) when is_binary(model) and model != "", do: true
  defp valid_agent_model?(_), do: false

  defp validate_agent_policy(nil), do: :ok

  defp validate_agent_policy(policy) when is_map(policy) do
    extras =
      policy
      |> Map.keys()
      |> Enum.filter(&(is_binary(&1) and &1 not in ~w(auto ask)))

    auto = policy["auto"]
    ask = policy["ask"]

    cond do
      extras != [] ->
        {:error,
         {:invalid_agent, "agent.policy unknown key(s): #{Enum.join(Enum.sort(extras), ", ")}"}}

      not (is_nil(auto) or string_list?(auto)) ->
        {:error, {:invalid_agent, "agent.policy.auto must be a list of strings"}}

      not (is_nil(ask) or string_list?(ask)) ->
        {:error, {:invalid_agent, "agent.policy.ask must be a list of strings"}}

      overlap?(auto, ask) ->
        {:error, {:invalid_agent, "agent.policy auto and ask must be disjoint"}}

      true ->
        :ok
    end
  end

  defp validate_agent_policy(other) do
    {:error, {:invalid_agent, "agent.policy must be an object, got: #{inspect(other)}"}}
  end

  defp string_list?(list) when is_list(list),
    do: Enum.all?(list, &(is_binary(&1) and &1 != ""))

  defp string_list?(_), do: false

  defp overlap?(auto, ask) when is_list(auto) and is_list(ask) do
    auto
    |> MapSet.new()
    |> MapSet.intersection(MapSet.new(ask))
    |> MapSet.size() > 0
  end

  defp overlap?(_, _), do: false

  # The tincture block is presentation metadata plus one capability grant:
  # `connect` feeds the served page's CSP connect-src. Shapes are enforced
  # for the keys the system reads (unknown extras stay open — the block is
  # descriptive); connect entries are held to the same domain grammar the
  # CSP builder applies, so a bad entry refuses at publish instead of
  # being dropped silently at serve time.
  defp validate_tincture_block(%{"tincture" => tincture}) when is_map(tincture) do
    connect = tincture["connect"]

    cond do
      not (is_nil(tincture["entry"]) or is_binary(tincture["entry"])) ->
        {:error, {:invalid_tincture, "tincture.entry must be a string"}}

      not (is_nil(connect) or is_list(connect)) ->
        {:error, {:invalid_tincture, "tincture.connect must be a list of domains"}}

      is_list(connect) and Enum.reject(connect, &valid_connect_domain?/1) != [] ->
        bad = Enum.reject(connect, &valid_connect_domain?/1)

        {:error,
         {:invalid_tincture,
          "tincture.connect entries must be bare domains (no scheme, port, " <>
            "path, IP, or bare wildcard), got: #{inspect(bad)}"}}

      not (is_nil(tincture["media"]) or is_map(tincture["media"])) ->
        {:error, {:invalid_tincture, "tincture.media must be an object"}}

      not (is_nil(tincture["window"]) or is_map(tincture["window"])) ->
        {:error, {:invalid_tincture, "tincture.window must be an object"}}

      true ->
        :ok
    end
  end

  defp validate_tincture_block(%{"tincture" => other}) do
    {:error, {:invalid_tincture, "tincture must be an object, got: #{inspect(other)}"}}
  end

  defp validate_tincture_block(_), do: :ok

  # Dependencies drive the activation graph and are one of the three
  # release-digest blocks — a malformed value must refuse at the one
  # validator, not surface later as a per-caller parse error. `static` is
  # the resolvable list; `dynamic` is a free-form discovery descriptor
  # (only its presence is read), so only its container shape is held.
  defp validate_dependencies_block(%{"dependencies" => deps}) when is_map(deps) do
    with :ok <- validate_static_deps(deps["static"]) do
      case deps["dynamic"] do
        nil ->
          :ok

        dynamic when is_map(dynamic) or is_list(dynamic) ->
          :ok

        other ->
          {:error,
           {:invalid_dependencies,
            "dependencies.dynamic must be an object or list, got: #{inspect(other)}"}}
      end
    end
  end

  defp validate_dependencies_block(%{"dependencies" => other}) do
    {:error, {:invalid_dependencies, "dependencies must be an object, got: #{inspect(other)}"}}
  end

  defp validate_dependencies_block(_), do: :ok

  defp validate_static_deps(nil), do: :ok

  defp validate_static_deps(list) when is_list(list) do
    case Enum.reject(list, &valid_dependency_entry?/1) do
      [] ->
        :ok

      bad ->
        {:error,
         {:invalid_dependencies,
          "dependencies.static entries must be ref strings or " <>
            "{\"ref\": ...} objects, got: #{inspect(bad)}"}}
    end
  end

  defp validate_static_deps(other) do
    {:error,
     {:invalid_dependencies, "dependencies.static must be a list, got: #{inspect(other)}"}}
  end

  defp valid_dependency_entry?(entry) when is_binary(entry), do: true
  defp valid_dependency_entry?(%{"ref" => ref}) when is_binary(ref), do: true
  defp valid_dependency_entry?(_), do: false
end
