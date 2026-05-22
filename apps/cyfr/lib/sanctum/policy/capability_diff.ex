# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Policy.CapabilityDiff do
  @moduledoc """
  Compares capability declarations between component versions.

  Diffs the `setup.policy` maps from two component manifests to detect
  capability escalation — new capability keys declared by a newer version
  that weren't present in the older version.
  """

  @capability_fields ~w(allowed_domains allowed_methods allowed_paths
                         allowed_actions allowed_private_ips allowed_tools
                         batch_timeout max_concurrent_tasks)

  @doc """
  Diff two `setup.policy` maps and return newly declared capability keys.

  Returns a list of capability field names that appear in `new_setup_policy`
  but not in `old_setup_policy`. Only checks known capability fields —
  universal fields (timeout, memory, etc.) are ignored.

  ## Parameters

  - `old_setup_policy` - The `setup.policy` map from the previous version (or `nil`)
  - `new_setup_policy` - The `setup.policy` map from the new version (or `nil`)

  ## Returns

  A list of newly declared capability field name strings.

  ## Examples

      iex> old = %{"allowed_domains" => ["api.stripe.com"]}
      iex> new = %{"allowed_domains" => ["api.stripe.com"], "allowed_paths" => ["data/"]}
      iex> Sanctum.Policy.CapabilityDiff.diff(old, new)
      ["allowed_paths"]

      iex> Sanctum.Policy.CapabilityDiff.diff(nil, %{"allowed_domains" => []})
      ["allowed_domains"]

  """
  @spec diff(map() | nil, map() | nil) :: [String.t()]
  def diff(old_setup_policy, new_setup_policy)

  def diff(_old, nil), do: []

  def diff(nil, new) when is_map(new) do
    new
    |> Map.keys()
    |> Enum.filter(&(&1 in @capability_fields))
    |> Enum.sort()
  end

  def diff(old, new) when is_map(old) and is_map(new) do
    old_keys = MapSet.new(Map.keys(old))

    new
    |> Map.keys()
    |> Enum.filter(fn key -> key in @capability_fields and key not in old_keys end)
    |> Enum.sort()
  end
end
