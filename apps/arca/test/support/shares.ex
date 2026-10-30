# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.Shares do
  @moduledoc """
  The rows a share test acts on, written through the storage facades as
  the layer above writes them: people, their own athanors, groups and
  seats, vault entries, shares, and profiles in another athanor whose head
  binds a share.
  """

  @destination ~s({"hosts":["api.example.com"],"methods":["GET"],"paths":["/v1/"],"scheme":"https"})

  @doc "A destination naming methods and paths, as a shared entry's must."
  @spec destination() :: String.t()
  def destination, do: @destination

  defp server, do: Prima.Actor.system()
  defp uniq, do: System.unique_integer([:positive])

  @doc "A person row."
  @spec person!(map()) :: map()
  def person!(overrides \\ %{}) do
    n = uniq()
    now = DateTime.utc_now()

    {:ok, user} =
      Arca.Test.People.mint(
        server(),
        Map.merge(
          %{
            id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
            provider: "github",
            email: "sh#{n}@example.com",
            email_verified: true,
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          },
          overrides
        ),
        %{
          key: "github|https://github.com|sh#{n}",
          provider: "github",
          issuer: "https://github.com",
          subject: "sh#{n}",
          first_seen_at: now,
          last_seen_at: now
        }
      )

    user
  end

  @doc """
  A person with their own athanor, seated in it: `%{user: _, athanor: _,
  actor: _}`, the actor the owner's own, naming them.
  """
  @spec owner!() :: %{user: map(), athanor: map(), actor: Prima.Actor.t()}
  def owner! do
    user = person!()
    n = uniq()

    {:ok, athanor} =
      Arca.Athanors.insert(server(), %{
        kind: "person",
        name: "Own #{n}",
        slug: "sh-own-#{n}",
        owner_user_id: user.id,
        created_by: user.id
      })

    {:ok, user} = Arca.Users.update(server(), user.id, %{personal_athanor_id: athanor.id})
    seat!(athanor.id, user.id)

    %{
      user: user,
      athanor: athanor,
      actor: %Prima.Actor{athanor_id: athanor.id, user_id: user.id, scope: :athanor}
    }
  end

  @doc "A group athanor with `members` (person ids) seated in it."
  @spec group!([String.t()], map()) :: map()
  def group!(members \\ [], attrs \\ %{}) do
    n = uniq()

    {:ok, athanor} =
      Arca.Athanors.insert(
        server(),
        Map.merge(%{kind: "group", name: "G#{n}", slug: "sh-g-#{n}", created_by: "system"}, attrs)
      )

    for member <- members, do: seat!(athanor.id, member)
    athanor
  end

  @doc "Seat the person `user_id` in the athanor `athanor_id`."
  @spec seat!(String.t(), String.t()) :: map()
  def seat!(athanor_id, user_id) do
    {:ok, row} =
      Arca.Members.seat(Prima.Actor.in_athanor(athanor_id), %{user_id: user_id, added_by: "x"})

    row
  end

  @doc "A vault entry of the actor's athanor, attach-only, of kind `api_key` and shareable."
  @spec entry!(Prima.Actor.t(), map()) :: map()
  def entry!(actor, over \\ %{}) do
    {:ok, entry} =
      Arca.VaultStorage.put(
        actor,
        Map.merge(
          %{
            name: "key-#{uniq()}",
            kind: "api_key",
            provider_hint: "example.com",
            sealed_payload: "sealed-bytes",
            binding_digest: "sha256:d0",
            destination: @destination
          },
          over
        )
      )

    entry
  end

  @doc "A share of `entry_id` to `everyone`, or to the audience `attrs` names."
  @spec share!(Prima.Actor.t(), String.t(), map()) :: map()
  def share!(actor, entry_id, attrs \\ %{}) do
    {:ok, share} =
      Arca.Shares.create(actor, Map.merge(%{entry_id: entry_id, audience: "everyone"}, attrs))

    share
  end

  @doc """
  A profile of the athanor `athanor_id` whose head binds the share
  `share_id` at `digest`: a recipient's grant. Answers the profile.
  """
  @spec bound!(String.t(), String.t(), String.t()) :: map()
  def bound!(athanor_id, share_id, digest \\ "sha256:d0") do
    {:ok, profile} =
      Arca.Test.Writers.put_profile(%{
        athanor_id: athanor_id,
        source_ref: "formula:local.consumer-#{uniq()}",
        kind: "owner",
        label: "default",
        status: "active"
      })

    {:ok, _consent} =
      Arca.ConsentStorage.insert_revision(
        revision_attrs(athanor_id, profile.id, 1),
        [share_ref(share_id, digest)],
        nil
      )

    profile
  end

  @doc "A share binding as a revision's writer names it."
  @spec share_ref(String.t(), String.t()) :: map()
  def share_ref(share_id, digest \\ "sha256:d0") do
    %{
      binding_key: "formula:local.consumer|@ingress|default",
      scope: "share",
      share_id: share_id,
      binding_digest: digest
    }
  end

  @doc "The attributes of revision `revision` of the profile `profile_id`."
  @spec revision_attrs(String.t(), String.t(), pos_integer()) :: map()
  def revision_attrs(athanor_id, profile_id, revision) do
    %{
      athanor_id: athanor_id,
      profile_id: profile_id,
      revision: revision,
      scope: "versionless",
      pinned_version: "",
      invoke_mode: "open_inert",
      shape_digest: "sha256:shape",
      commit_digest: "sha256:commit",
      blob_digest: Prima.Digest.sha256("{}"),
      resolved_policy: "{}",
      activation: "{}",
      admitted_origins: [:interactive],
      granted_by: "test",
      granted_via: "bootstrap"
    }
  end

  @doc "The status of the profile `profile_id` of the athanor `athanor_id`."
  @spec profile_status(String.t(), String.t()) :: String.t()
  def profile_status(athanor_id, profile_id) do
    {:ok, profile} = Arca.ProfileStorage.get(Prima.Actor.in_athanor(athanor_id), profile_id)
    profile.status
  end

  @doc "The status of the share `share_id` of the actor's athanor."
  @spec share_status(Prima.Actor.t(), String.t()) :: String.t()
  def share_status(actor, share_id) do
    {:ok, share} = Arca.Shares.get(actor, share_id)
    share.status
  end
end
