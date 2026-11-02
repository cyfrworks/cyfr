# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.InvitationTest do
  @moduledoc """
  The `invitation` tool through the gate: `create` answers the code once,
  with the link that opens it, under keys the request log redacts, and
  keeps the name it offers its newcomer for the invitation page; `list`
  and `revoke` answer the invitation without it; no answer carries a
  null; and each is a person's act, which an API key is refused.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Context

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    n = System.unique_integer([:positive])

    [alice, ops] =
      for name <- ["alice", "ops"] do
        {:ok, user} =
          Sanctum.Test.People.linked(%{
            id: "github|https://github.com|invitation-#{name}-#{n}",
            provider: "github"
          })

        user.id
      end

    {:ok, _} = Sanctum.TestContext.ensure_platform(ops)
    {:ok, thread} = Sanctum.SharedThreads.create(alice, "Invitation tool #{n}")
    {:ok, alice: alice, ops: ops, thread: thread}
  end

  defp call(ctx, args), do: Sanctum.Gate.call_external("invitation", ctx, args)

  defp ctx(user_id, opts \\ []) do
    Context.build(
      user_id: user_id,
      athanor_id: Keyword.get(opts, :athanor_id, Sanctum.TestContext.athanor_id()),
      provider: "github",
      permissions: [:*],
      scope: :athanor,
      auth_method: Keyword.get(opts, :auth_method, :oidc),
      authenticated: true,
      platform_admin: Keyword.get(opts, :platform_admin, false)
    )
  end

  # Every value in the answer, at any depth, is present: an absent value
  # is an absent key.
  defp nulls(value) when is_map(value), do: Enum.flat_map(value, fn {_k, v} -> nulls(v) end)
  defp nulls(value) when is_list(value), do: Enum.flat_map(value, &nulls/1)
  defp nulls(nil), do: [nil]
  defp nulls(_value), do: []

  test "create answers the code once with its link, and list and revoke answer the invitation without it",
       %{alice: alice, thread: thread} do
    assert {:ok, %{invitation: invitation, code: code, invitation_url: link} = created} =
             call(ctx(alice), %{"action" => "create", "thread_id" => thread.id})

    assert link == Sanctum.Person.home() <> "/invite#" <> code
    assert %{state: "pending", thread_id: thread_id, thread_title: title} = invitation
    assert {thread_id, title} == {thread.id, thread.title}
    assert nulls(created) == []

    refute inspect(Prima.Sanitizer.sanitize(created)) =~ code
    refute Enum.any?(Arca.Repo.all(Arca.Schemas.McpLog), &(inspect(&1) =~ code))

    assert {:ok, %{invitations: [listed], count: 1} = answer} =
             call(ctx(alice), %{"action" => "list"})

    assert listed == invitation
    refute inspect(answer) =~ code

    assert {:ok, %{invitation: %{state: "revoked"} = revoked}} =
             call(ctx(alice), %{"action" => "revoke", "invitation_id" => invitation.id})

    refute Map.has_key?(revoked, :code)
  end

  test "create keeps the name it offers, which the invitation page reads, and refuses one that is no name",
       %{alice: alice, thread: thread} do
    assert {:ok, %{invitation: invitation, code: code}} =
             call(ctx(alice), %{"action" => "create", "thread_id" => thread.id, "name" => "mira"})

    assert Arca.Repo.get!(Arca.Schemas.Invitation, invitation.id).name == "mira"
    assert {:ok, %{name: "mira"}} = Sanctum.Invitations.lookup(code)

    assert {:error, reason} =
             call(ctx(alice), %{
               "action" => "create",
               "thread_id" => thread.id,
               "name" => "Not A Name"
             })

    assert %Prima.Refusal{class: :invalid_argument} = Sanctum.Refusals.classify(reason)
    assert Arca.Repo.aggregate(Arca.Schemas.Invitation, :count) == 1
  end

  test "an invitation naming no thread carries no thread keys and no null", %{ops: ops} do
    assert {:ok, %{invitation: invitation} = created} =
             call(ctx(ops, platform_admin: true), %{"action" => "create"})

    refute Map.has_key?(invitation, :thread_id)
    refute Map.has_key?(invitation, :thread_title)
    assert nulls(created) == []
  end

  test "an API key is refused every action, and nothing is written", %{
    alice: alice,
    thread: thread
  } do
    key = ctx(alice, auth_method: :api_key)

    for args <- [
          %{"action" => "create", "thread_id" => thread.id},
          %{"action" => "list"},
          %{"action" => "revoke", "invitation_id" => "inv_any"}
        ] do
      assert {:error, reason} = call(key, args)
      assert Sanctum.Refusals.render(reason) =~ "person's act"
    end

    assert Arca.Repo.aggregate(Arca.Schemas.Invitation, :count) == 0
  end
end
