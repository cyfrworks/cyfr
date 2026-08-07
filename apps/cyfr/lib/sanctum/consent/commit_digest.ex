# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.CommitDigest do
  @moduledoc """
  The shape plus every decision made on it — the exact thing an operator
  approves and a proof binds.

  Where the shape digest is the question, this is the answer: which vault
  entry satisfies which need, what is projected out of it, which slots bind
  where, whether an override was taken, what limits were resolved. Change
  any of it and the digest changes, so an authorization minted against one
  set of decisions cannot cover another.

  The shape digest is embedded as a **string** rather than re-expanding the
  shape fields. That keeps the input small, and it makes "does this proof
  cover the shape the operator previewed?" a direct comparison instead of a
  structural re-derivation.

  Vault bindings carry both the entry id and its binding digest. The entry
  id alone would let a rebinding — the same entry pointed at a different
  account or different endpoints — inherit an existing consent silently.
  """

  alias Sanctum.Consent.Normalize
  alias Sanctum.JCS

  @type binding :: %{
          required(:need) => String.t(),
          required(:entry_id) => String.t(),
          required(:binding_digest) => String.t(),
          optional(:fields) => [String.t()],
          optional(:scopes) => [String.t()]
        }

  @type tool_server_grant :: %{
          required(:server_name) => String.t(),
          required(:server_digest) => String.t(),
          required(:tool_patterns) => [String.t()]
        }

  @type commit :: %{
          required(:shape_digest) => String.t(),
          required(:kind) => :owner | :public,
          required(:invoke_mode) => :open_inert | :edge_only,
          optional(:bindings) => [binding()],
          optional(:slot_bindings) => %{String.t() => String.t()},
          optional(:tool_servers) => [tool_server_grant()],
          optional(:override) => boolean(),
          optional(:limits) => map()
        }

  @type error :: {:invalid_commit, atom(), String.t()} | {:invalid_digest_input, JCS.error()}

  @doc """
  Compute the commit digest.

  ## Examples

      iex> {:ok, digest} = Sanctum.Consent.CommitDigest.compute(%{
      ...>   shape_digest: "sha256:abc",
      ...>   kind: :owner,
      ...>   invoke_mode: :open_inert
      ...> })
      iex> String.starts_with?(digest, "sha256:")
      true

  """
  @spec compute(commit()) :: {:ok, String.t()} | {:error, error()}
  def compute(commit) when is_map(commit) do
    with {:ok, canonical} <- normalize(commit) do
      case JCS.hash(canonical) do
        {:ok, digest} -> {:ok, digest}
        {:error, reason} -> {:error, {:invalid_digest_input, reason}}
      end
    end
  end

  def compute(other),
    do: {:error, {:invalid_commit, :input, "expected a map, got: #{inspect(other)}"}}

  @doc """
  The canonical map the commit digest is taken over.
  """
  @spec normalize(commit()) :: {:ok, map()} | {:error, error()}
  def normalize(commit) do
    tag = :invalid_commit

    with :ok <-
           Normalize.only_keys(
             commit,
             ~w(shape_digest kind invoke_mode bindings slot_bindings tool_servers override limits)a,
             tag
           ),
         {:ok, shape_digest} <- Normalize.required_string(commit, :shape_digest, tag),
         {:ok, kind} <- Normalize.enum(commit, :kind, [:owner, :public], tag),
         {:ok, invoke_mode} <-
           Normalize.enum(commit, :invoke_mode, [:open_inert, :edge_only], tag),
         :ok <- check_public_is_contained(kind, invoke_mode),
         {:ok, bindings} <- bindings(commit),
         {:ok, slot_bindings} <- slot_bindings(commit),
         {:ok, tool_servers} <- tool_servers(commit),
         {:ok, override} <- override(commit),
         {:ok, limits} <- Normalize.caps(commit, :limits, tag) do
      {:ok,
       %{
         "shape_digest" => shape_digest,
         "kind" => Atom.to_string(kind),
         "invoke_mode" => Atom.to_string(invoke_mode),
         "bindings" => bindings,
         "slot_bindings" => slot_bindings,
         "tool_servers" => tool_servers,
         "override" => override,
         "limits" => limits
       }}
    end
  end

  # A public profile that could invoke freely would let an anonymous caller
  # reach anything the component can name. Refusing it here means a commit
  # digest for such a consent cannot even be computed.
  defp check_public_is_contained(:public, :open_inert) do
    {:error, {:invalid_commit, :invoke_mode, "public profiles must be edge_only"}}
  end

  defp check_public_is_contained(_kind, _invoke_mode), do: :ok

  defp bindings(commit) do
    tag = :invalid_commit

    case Map.get(commit, :bindings, []) do
      list when is_list(list) ->
        list
        |> Enum.reduce_while({:ok, []}, fn binding, {:ok, acc} ->
          case normalize_binding(binding) do
            {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, bindings} -> ensure_one_binding_per_need(bindings)
          error -> error
        end

      other ->
        {:error, {tag, :bindings, "must be a list, got: #{inspect(other)}"}}
    end
  end

  defp normalize_binding(binding) when is_map(binding) do
    tag = :invalid_commit

    with :ok <- Normalize.only_keys(binding, ~w(need entry_id binding_digest fields scopes)a, tag),
         {:ok, need} <- Normalize.required_string(binding, :need, tag),
         {:ok, entry_id} <- Normalize.required_string(binding, :entry_id, tag),
         {:ok, binding_digest} <- Normalize.required_string(binding, :binding_digest, tag),
         {:ok, fields} <- Normalize.string_set(binding, :fields, tag),
         {:ok, scopes} <- Normalize.string_set(binding, :scopes, tag) do
      {:ok,
       %{
         "need" => need,
         "entry_id" => entry_id,
         "binding_digest" => binding_digest,
         "fields" => fields,
         "scopes" => scopes
       }}
    end
  end

  defp normalize_binding(other) do
    {:error, {:invalid_commit, :bindings, "each binding must be a map, got: #{inspect(other)}"}}
  end

  # One need, one credential. Two bindings for the same need would make the
  # digest depend on list order and leave the loader to pick.
  defp ensure_one_binding_per_need(bindings) do
    sorted = Enum.sort_by(bindings, & &1["need"])
    needs = Enum.map(sorted, & &1["need"])

    if length(Enum.uniq(needs)) == length(needs) do
      {:ok, sorted}
    else
      {:error, {:invalid_commit, :bindings, "each need may be bound exactly once"}}
    end
  end

  # Like vault bindings, a tool-server grant carries both the name and
  # the config digest — the digest is what matching keys on, the name is
  # what makes a later mismatch explainable. One grant per server.
  defp tool_servers(commit) do
    tag = :invalid_commit

    case Map.get(commit, :tool_servers, []) do
      list when is_list(list) ->
        list
        |> Enum.reduce_while({:ok, []}, fn grant, {:ok, acc} ->
          case normalize_tool_server(grant) do
            {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, grants} -> ensure_one_grant_per_server(grants)
          error -> error
        end

      other ->
        {:error, {tag, :tool_servers, "must be a list, got: #{inspect(other)}"}}
    end
  end

  defp normalize_tool_server(grant) when is_map(grant) do
    tag = :invalid_commit

    with :ok <- Normalize.only_keys(grant, ~w(server_name server_digest tool_patterns)a, tag),
         {:ok, name} <- Normalize.required_string(grant, :server_name, tag),
         {:ok, digest} <- Normalize.required_string(grant, :server_digest, tag),
         {:ok, patterns} <- Normalize.string_set(grant, :tool_patterns, tag) do
      {:ok, %{"server_name" => name, "server_digest" => digest, "tool_patterns" => patterns}}
    end
  end

  defp normalize_tool_server(other) do
    {:error, {:invalid_commit, :tool_servers, "each grant must be a map, got: #{inspect(other)}"}}
  end

  defp ensure_one_grant_per_server(grants) do
    sorted = Enum.sort_by(grants, & &1["server_name"])
    names = Enum.map(sorted, & &1["server_name"])

    if length(Enum.uniq(names)) == length(names) do
      {:ok, sorted}
    else
      {:error, {:invalid_commit, :tool_servers, "each server may be granted exactly once"}}
    end
  end

  defp slot_bindings(commit) do
    tag = :invalid_commit

    case Map.get(commit, :slot_bindings, %{}) do
      map when is_map(map) ->
        if Enum.all?(map, fn {k, v} -> is_binary(k) and k != "" and is_binary(v) and v != "" end) do
          {:ok, Map.new(map)}
        else
          {:error, {tag, :slot_bindings, "must map non-empty strings to non-empty strings"}}
        end

      other ->
        {:error, {tag, :slot_bindings, "must be a map, got: #{inspect(other)}"}}
    end
  end

  defp override(commit) do
    case Map.get(commit, :override, false) do
      value when is_boolean(value) -> {:ok, value}
      other -> {:error, {:invalid_commit, :override, "must be a boolean, got: #{inspect(other)}"}}
    end
  end
end
