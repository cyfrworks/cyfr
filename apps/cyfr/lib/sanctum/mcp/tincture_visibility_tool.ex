# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.TinctureVisibilityTool do
  @moduledoc """
  Tincture visibility tool handlers for the Sanctum MCP provider — set and
  get a tincture's public/private visibility.

  Extracted from `Sanctum.MCP`; behaviour preserved exactly.
  """

  alias Sanctum.Context

  def handle(%Context{} = ctx, %{
        "action" => "set",
        "publisher" => publisher,
        "name" => name,
        "public" => is_public
      })
      when is_boolean(is_public) do
    with :ok <- Context.authorize(ctx, :execute) do
      ref = "tincture:#{publisher}.#{name}"

      # Preserve all existing policy fields, only update is_public
      existing =
        case Sanctum.Policy.get_effective(ctx, ref) do
          {:ok, policy, _meta} -> Sanctum.PolicyStore.policy_to_update_map(policy)
          _ -> %{}
        end

      policy_map = Map.merge(existing, %{component_type: "tincture", is_public: is_public})

      case Sanctum.PolicyStore.put(ctx, ref, policy_map) do
        :ok ->
          {:ok,
           %{
             status: "visibility_updated",
             publisher: publisher,
             name: name,
             public: is_public,
             org: ctx.org_id,
             project: ctx.project_id
           }}

        {:error, reason} ->
          {:error, "Failed to set visibility: #{inspect(reason)}"}
      end
    end
  end

  def handle(_ctx, %{"action" => "set"}) do
    {:error, "set action requires publisher, name, and public (boolean) parameters"}
  end

  def handle(%Context{} = ctx, %{
        "action" => "get",
        "publisher" => publisher,
        "name" => name
      }) do
    with :ok <- Context.authorize(ctx, :read) do
      ref = "tincture:#{publisher}.#{name}"

      case Sanctum.Policy.get_effective(ctx, ref) do
        {:ok, policy, %{source: source}} ->
          result = %{
            publisher: publisher,
            name: name,
            public: policy.is_public == true,
            org: ctx.org_id,
            project: ctx.project_id
          }

          if source in [:hardcoded_default, :type_default] do
            {:ok, Map.put(result, :note, "No policy record — defaults to private")}
          else
            {:ok, result}
          end

        {:error, _reason} ->
          {:ok,
           %{
             publisher: publisher,
             name: name,
             public: false,
             note: "No policy — defaults to private"
           }}
      end
    end
  end

  def handle(_ctx, %{"action" => "get"}) do
    {:error, "get action requires publisher and name parameters"}
  end

  def handle(_ctx, _args) do
    {:error, "Invalid tincture_visibility action. Use: set, get"}
  end
end
