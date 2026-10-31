# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.ShareFixtures do
  @moduledoc """
  Two people on one CYFR and a key one of them shares, as the consent
  walk meets them: Terry and Alice, each signed in to their own athanor
  and seated together in the group Traders, and Terry's attach-only key
  for the openai.com inference API shared with Traders (`traders!/0`).
  The rows are written through the storage facades (`Arca.Test.Shares`);
  each person's context is a signed-in person's in their own athanor,
  admitted through Prism, where a share is bound.
  """

  alias Sanctum.VaultReader

  @destination ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"})
  @moved ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v2/"],"scheme":"https"})

  @doc "The destination of the shared key: where it may go, methods and paths named."
  @spec destination() :: String.t()
  def destination, do: @destination

  @doc """
  Terry, Alice, the group Traders holding both, Terry's key (`entry`) and
  its share with Traders (`share`).
  """
  @spec traders!() :: map()
  def traders! do
    terry = person!("Terry")
    alice = person!("Alice")
    traders = Arca.Test.Shares.group!([terry.user.id, alice.user.id])
    entry = key!(terry)

    share =
      Arca.Test.Shares.share!(terry.actor, entry.id, %{audience: "group", group_id: traders.id})

    %{terry: terry, alice: alice, traders: traders, entry: entry, share: share}
  end

  @doc """
  A person named `display_name` with their own athanor, seated in it:
  `%{user: _, athanor: _, actor: _, ctx: _}`, `ctx` their signed-in
  context there.
  """
  @spec person!(String.t()) :: map()
  def person!(display_name) do
    owner = Arca.Test.Shares.owner!()

    {:ok, user} =
      Arca.Users.update(Prima.Actor.system(), owner.user.id, %{display_name: display_name})

    # The suite's signed-in person (`Sanctum.TestContext.local/0`), named
    # for this person in their own athanor.
    ctx = %{
      Sanctum.TestContext.local()
      | user_id: user.id,
        provider: "github",
        namespace: "share-#{System.unique_integer([:positive])}",
        athanor_id: owner.athanor.id
    }

    Map.merge(owner, %{user: user, ctx: Sanctum.TestContext.via(ctx, :prism)})
  end

  @doc """
  An attach-only openai.com key of `owner`'s athanor, its one field
  `OPENAI_API_KEY`, stored at the digest its binding columns derive.
  """
  @spec key!(map()) :: map()
  def key!(%{actor: actor}) do
    attrs = %{
      kind: "api_key",
      provider_hint: "openai.com",
      field_names: ~s(["OPENAI_API_KEY"]),
      destination: @destination,
      attach_only: true
    }

    {:ok, digest} =
      VaultReader.binding_digest(Map.merge(attrs, %{oauth_endpoints: nil, oauth_scopes: nil}))

    Arca.Test.Shares.entry!(actor, Map.put(attrs, :binding_digest, digest))
  end

  @doc """
  `owner` rebinds `entry`: its paths move, and with them the digest its
  binding columns derive, through the one binding move every rebind
  makes. Answers the new digest.
  """
  @spec rebind!(map(), map()) :: String.t()
  def rebind!(%{actor: actor}, entry) do
    {:ok, row} = Arca.VaultStorage.get(actor, entry.id)
    {:ok, digest} = VaultReader.binding_digest(%{row | destination: @moved})

    {:ok, _moved} =
      Arca.VaultStorage.move_binding(
        actor,
        entry.id,
        row.binding_digest,
        %{destination: @moved, binding_digest: digest},
        Sanctum.Vault.blocked_profile_status()
      )

    digest
  end

  @doc "`person` leaves `group`, as the leave transition writes it."
  @spec leave!(map(), map()) :: :ok
  def leave!(group, %{user: user}) do
    {:ok, _left} =
      Arca.SecurityTransitions.leave_athanor(Prima.Actor.in_athanor(group.id), user.id,
        verify: fn _ -> :ok end
      )

    :ok
  end
end
