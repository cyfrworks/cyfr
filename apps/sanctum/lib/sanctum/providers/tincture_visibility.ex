# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.TinctureVisibility do
  @moduledoc """
  Tincture visibility for the Sanctum MCP provider.

  Public-ness is a published profile, not a policy bit: `get` reports
  whether an active public profile exists. There is no `set` — publishing
  is a consent decision with its own proof-bound walk (`profile.publish`),
  and unpublishing is `profile.revoke` of the public profile. A tincture
  with no profile row at all is told how to publish one. A store that
  could not answer is refused `{:unavailable, "Consent profiles"}`, and a
  profile row that does not decode `{:corrupt, {:profile, id}}`, since it
  may be the public one; neither is read as a tincture with no profile.
  """

  alias Sanctum.Context

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
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
        "Report whether a tincture has an active public profile. Public-ness is a published profile, not a policy bit — publish with profile.publish, unpublish with profile.revoke. A store that could not answer, or a profile row that is damaged, is refused, never read as a tincture with no profile.",
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

      case Arca.ConsentStorage.profile_entries(Context.actor(ctx), ref) do
        {:ok, entries} ->
          answer(ctx, publisher, name, entries)

        # A store that could not answer says nothing about the tincture's
        # profiles, so it is refused rather than read as having none.
        {:error, _unanswered} ->
          {:error, {:unavailable, "Consent profiles"}}
      end
    end
  end

  def handle(_ctx, %{"action" => "get"}) do
    {:error, "get action requires publisher and name parameters"}
  end

  def handle(_ctx, _args) do
    {:error, Prima.Provider.invalid_action("tincture_visibility", action_enum())}
  end

  # A profile row whose kind or status is outside the closed vocabulary may
  # be the public one, so the tincture's visibility cannot be read: it is
  # refused as the admission refuses it, never told to publish over a
  # record that exists.
  defp answer(ctx, publisher, name, entries) do
    case Enum.find(entries, &(&1.status == :corrupt)) do
      %{id: id} ->
        {:error, {:corrupt, {:profile, id}}}

      nil ->
        public = Enum.find(entries, &(&1.kind == :public and &1.status == :active))

        result = %{
          publisher: publisher,
          name: name,
          public: public != nil,
          athanor: ctx.athanor_id,
          url: public_url(ctx, publisher, name)
        }

        {:ok, visibility(result, public, entries)}
    end
  end

  # The public profile's id when there is one, and the way to publish when
  # the tincture has no profile at all.
  defp visibility(result, %{id: id}, _profiles), do: Map.put(result, :public_profile_id, id)

  defp visibility(result, nil, []),
    do: Map.put(result, :note, "No profiles — publish with profile.publish")

  defp visibility(result, nil, _profiles), do: result

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
