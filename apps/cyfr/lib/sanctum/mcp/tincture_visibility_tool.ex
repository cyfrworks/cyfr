# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.TinctureVisibilityTool do
  @moduledoc """
  Tincture visibility for the Sanctum MCP provider.

  Public-ness is a published profile, not a policy bit: `get` reports
  whether an active public profile exists, and `set` no longer flips
  anything — publishing is a consent decision with its own proof-bound
  walk (`profile.publish`), and unpublishing is `profile.revoke` of the
  public profile. The error text says exactly that, so a caller holding
  the old vocabulary learns the new one.
  """

  alias Sanctum.Consent.Source
  alias Sanctum.Context

  def handle(%Context{} = ctx, %{
        "action" => "set",
        "publisher" => publisher,
        "name" => name,
        "public" => is_public
      })
      when is_boolean(is_public) do
    with :ok <- Context.authorize(ctx, :execute) do
      if is_public do
        {:error,
         "publishing is a consent decision — run profile.publish on " <>
           "tincture:#{publisher}.#{name}'s owner profile (plan → preview → commit)"}
      else
        {:error,
         "unpublishing revokes the public profile — run profile.revoke on " <>
           "tincture:#{publisher}.#{name}'s public profile"}
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
    {:error, "Invalid tincture_visibility action. Use: set, get"}
  end
end
