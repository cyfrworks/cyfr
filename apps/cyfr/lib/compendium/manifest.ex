# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Manifest do
  @moduledoc """
  Shared manifest decoding utilities.

  Normalizes manifest values from various storage representations
  (nil, JSON string, map) into a consistent map format.
  """

  require Logger

  @doc """
  Decode a manifest value into a map.

  Handles nil (returns empty map), maps (passthrough), and JSON strings.
  Returns an empty map on decode failure — a malformed manifest degrades to
  "no declarations", so the failure is logged to avoid a silent capability gap.
  """
  @spec decode(nil | map() | binary()) :: map()
  def decode(nil), do: %{}
  def decode(manifest) when is_map(manifest), do: manifest

  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) ->
        map

      other ->
        Logger.warning(
          "[Compendium.Manifest] manifest decode failed (#{inspect(elem_or_self(other))}); " <>
            "treating as empty — declared capabilities will be missing"
        )

        %{}
    end
  end

  def decode(_), do: %{}

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

  # The closed top-level key roster — every field a manifest may carry,
  # which is also the roster component-guide.md documents. Identity fields
  # are validated against the directory at registration
  # (`Registry.validate_manifest_identity`); presentational fields are
  # free text; `needs`/`caps` delegate to their owners below.
  @known_keys ~w(
    name type version publisher
    description license tags category
    needs caps dependencies tincture
    schema examples defaults forked_from
    contracts agent
  )

  # A contract is `<family>/<name>@<major>`: the operations a component
  # answers on its one export, named so a host can ask for them by name
  # (`Cyfr.Models` reads `model/chat@1`).
  @contract_pattern ~r/\A[a-z][a-z0-9-]*\/[a-z][a-z0-9-]*@[1-9][0-9]*\z/

  @doc "The closed top-level manifest key roster (docs derive from this)."
  @spec known_keys() :: [String.t()]
  def known_keys, do: @known_keys

  @doc """
  The contracts a manifest declares (`"contracts": ["model/chat@1"]`), as
  written; an absent or malformed block declares none.
  """
  @spec contracts(map()) :: [String.t()]
  def contracts(%{"contracts" => list}) when is_list(list),
    do: Enum.filter(list, &(is_binary(&1) and Regex.match?(@contract_pattern, &1)))

  def contracts(_), do: []

  @doc """
  Validate a decoded manifest at a write boundary — the ONE manifest
  validator, called by every ingress (directory registration,
  `publish_bytes`, tincture publish; OCI store lands through those).

  The refusals, in order:

      * unknown top-level keys;
      * malformed `needs` or `caps` blocks;
      * malformed `tincture` or `dependencies` blocks, which feed CSP,
        activation-graph and release-digest validation;
      * a `contracts` block that is not a list of `family/name@major` names.
  """
  @spec validate(map()) :: :ok | {:error, term()}
  def validate(manifest) when is_map(manifest) do
    with :ok <- reject_unknown_keys(manifest),
         :ok <- Compendium.Manifest.Needs.validate(manifest),
         :ok <- Compendium.Manifest.Caps.validate(manifest),
         :ok <- validate_tincture_block(manifest),
         :ok <- validate_contracts_block(manifest),
         :ok <- validate_agent_block(manifest) do
      validate_dependencies_block(manifest)
    end
  end

  def validate(_), do: :ok

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

  # The `agent` block is the projected consent shape of an AQUA agent
  # (`Compendium.AgentSource`): catalyst, model, and the auto/ask policy
  # sets. It is refused on every other type.
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

      is_list(connect) and
          Enum.reject(connect, &Cyfr.TinctureHelpers.valid_connect_domain?/1) != [] ->
        bad = Enum.reject(connect, &Cyfr.TinctureHelpers.valid_connect_domain?/1)

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
  # (`DependencyResolver.has_dynamic_deps?/1` only presence-checks it), so
  # only its container shape is held.
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

  @doc """
  The suggested vocabulary for the manifest's `category` field — the one
  roster the MCP categories action serves. The field itself is free
  text (search filters on whatever a manifest declared); this names the
  recommended values without enforcing them.
  """
  @spec known_categories() :: [%{name: String.t(), description: String.t()}]
  def known_categories do
    [
      %{name: "api-integrations", description: "External API connectors"},
      %{name: "data-processing", description: "Data transformation and analysis"},
      %{name: "ai-ml", description: "Machine learning and AI tools"},
      %{name: "security", description: "Security and cryptography"},
      %{name: "utilities", description: "General-purpose utilities"}
    ]
  end

  defp elem_or_self({:error, reason}), do: reason
  defp elem_or_self(other), do: other
end
