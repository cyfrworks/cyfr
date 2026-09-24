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

  alias Sanctum.Context

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.MCP assembles its roster from these.
  def definition do
    alias Prima.{Arg, Operation}

    Operation.tool(
      [
        Operation.new(
          "tincture_visibility",
          "get",
          "Get tincture visibility",
          [
            Arg.new("publisher", :string,
              required: true,
              description: "Tincture publisher (e.g. 'local', 'moonmoon69')"
            ),
            Arg.new("name", :string, required: true, description: "Tincture name")
          ],
          kind: :read,
          planes: [:external, :in_chain],
          permission: :storage_read
        )
      ],
      description:
        "Report whether a tincture has an active public profile. Public-ness is a published profile, not a policy bit — publish with profile.publish, unpublish with profile.revoke.",
      title: "Tincture Visibility"
    )
  end

  def handle(%Context{} = ctx, %{
        "action" => "get",
        "publisher" => publisher,
        "name" => name
      }) do
    # Dispatch enforces auth + :storage_read; the tenant residual keeps an
    # athanor-less context out of the profile store.
    with :ok <- Context.tenant_ok(ctx) do
      ref = Prima.ComponentRef.build("tincture", publisher, name)

      case Arca.ConsentStorage.profiles(Context.actor(ctx), ref) do
        {:ok, profiles} ->
          public =
            Enum.find(profiles, &(&1.kind == :public and &1.status == :active))

          result = %{
            publisher: publisher,
            name: name,
            public: public != nil,
            athanor: ctx.athanor_id,
            url: public_url(ctx, publisher, name)
          }

          result =
            if public, do: Map.put(result, :public_profile_id, public.id), else: result

          {:ok, result}

        {:error, _reason} ->
          # Same shape as the answer above, so a client never has to guess
          # which keys are there.
          {:ok,
           %{
             publisher: publisher,
             name: name,
             public: false,
             athanor: ctx.athanor_id,
             url: public_url(ctx, publisher, name),
             note: "No profiles — publish with profile.publish"
           }}
      end
    end
  end

  def handle(_ctx, %{"action" => "get"}) do
    {:error, "get action requires publisher and name parameters"}
  end

  def handle(_ctx, _args) do
    {:error, Prima.Provider.invalid_action("tincture_visibility", action_enum())}
  end

  # The finished public URL, so no client composes the route shape itself.
  # An athanor that cannot be resolved (archived mid-request) yields nil.
  defp public_url(ctx, publisher, name) do
    case Sanctum.Tenancy.Athanors.get(ctx.athanor_id) do
      {:ok, athanor} ->
        Prima.TinctureUrl.path(
          Sanctum.Tenancy.Athanors.route_slug(athanor),
          publisher,
          name
        )

      _ ->
        nil
    end
  end

  defp action_enum, do: Prima.Provider.action_enum(definition())
end
