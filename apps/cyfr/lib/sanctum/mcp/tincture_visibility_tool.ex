# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.TinctureVisibilityTool do
  @moduledoc """
  Tincture visibility for the Sanctum MCP provider.

  Public-ness is a published profile, not a policy bit: `get` reports
  whether an active public profile exists. There is no `set` — publishing
  is a consent decision with its own proof-bound walk (`profile.publish`),
  and unpublishing is `profile.revoke` of the public profile.
  """

  alias Sanctum.Consent.Source
  alias Sanctum.Context

  def handle(%Context{} = ctx, %{
        "action" => "get",
        "publisher" => publisher,
        "name" => name
      }) do
    # Dispatch enforces auth + :storage_read; the tenant residual keeps an
    # org-less context out of the profile store.
    with :ok <- tenant_gate(ctx) do
      ref = "tincture:#{publisher}.#{name}"

      case Source.impl().profiles(ctx, ref) do
        {:ok, profiles} ->
          public =
            Enum.find(profiles, &(&1.kind == :public and &1.status == :active))

          result = %{
            publisher: publisher,
            name: name,
            public: public != nil,
            org: ctx.org_id,
            project: ctx.project_id
          }

          result =
            if public, do: Map.put(result, :public_profile_id, public.id), else: result

          {:ok, result}

        {:error, _reason} ->
          {:ok,
           %{
             publisher: publisher,
             name: name,
             public: false,
             note: "No profiles — publish with profile.publish"
           }}
      end
    end
  end

  def handle(_ctx, %{"action" => "get"}) do
    {:error, "get action requires publisher and name parameters"}
  end

  def handle(_ctx, _args) do
    {:error, "Invalid tincture_visibility action. Use: get"}
  end

  defp tenant_gate(ctx) do
    case Context.tenant_ok(ctx) do
      :ok -> :ok
      {:error, :missing_tenant} -> {:error, "Unauthorized: no resolved tenant"}
    end
  end
end
