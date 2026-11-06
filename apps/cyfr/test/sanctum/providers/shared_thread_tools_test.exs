# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.SharedThreadToolsTest do
  @moduledoc """
  The `shared_thread` tool through the gate: every action is a signed-in
  person's and an API key is refused for each; each action answers its
  shape; a refusal reaches the caller as its sentence; `pair` is
  interactive on its annotation.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.Refusals

  @actions ~w(create pair get list rename archive unarchive leave people add remove withdraw post messages attach)

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    n = System.unique_integer([:positive])

    [alice, bob, carol] =
      for name <- ~w(alice bob carol) do
        {:ok, user} =
          Sanctum.Test.People.linked(%{
            id: "github|https://github.com|stt-#{name}-#{n}",
            provider: "github",
            email: "stt-#{name}#{n}@example.com",
            verified: true
          })

        user.id
      end

    {:ok, alice: alice, bob: bob, carol: carol}
  end

  defp ctx(user_id, opts \\ []) do
    Context.build(
      user_id: user_id,
      athanor_id: Sanctum.TestContext.athanor_id(),
      provider: "github",
      permissions: [:*],
      scope: :athanor,
      auth_method: Keyword.get(opts, :auth_method, :oidc),
      authenticated: true
    )
  end

  defp call(ctx, args), do: Sanctum.Gate.call_external("shared_thread", ctx, args)

  defp identifier, do: "per_" <> Prima.Digest.sha256_hex("stt-#{System.unique_integer()}")

  defp thread!(by, title \\ "Plans") do
    {:ok, thread} = call(by, %{"action" => "create", "title" => title})
    thread
  end

  test "an API key is refused for every action", %{alice: alice, bob: bob} do
    a = ctx(alice)
    thread = thread!(a)
    key = ctx(alice, auth_method: :api_key)

    t = %{"thread" => thread.id}
    file = %{"filename" => "a.txt", "media_type" => "text/plain", "data" => "YQ=="}

    args = %{
      "create" => %{"title" => "Key"},
      "pair" => %{"user" => bob},
      "get" => t,
      "list" => %{},
      "rename" => Map.put(t, "title", "Key"),
      "archive" => t,
      "unarchive" => t,
      "leave" => t,
      "people" => t,
      "add" => Map.put(t, "user_id", bob),
      "remove" => Map.put(t, "user_id", alice),
      "withdraw" => Map.put(t, "identifier", identifier()),
      "post" => Map.put(t, "content", "hi"),
      "messages" => t,
      "attach" => Map.put(t, "files", [file])
    }

    assert Enum.sort(Map.keys(args)) == Enum.sort(@actions)

    for action <- @actions do
      assert {:error, reason} = call(key, Map.put(args[action], "action", action)), action

      if action == "pair" do
        # `consent: :interactive`: the registry refuses a key before the handler runs.
        assert %Prima.Refusal{
                 stage: :admission,
                 reason: {:consent_class_required, {:surface_not_permitted, :api_key}}
               } = reason
      else
        assert Refusals.render(reason) =~ "person's act", action
      end
    end

    # Nothing the key asked was done.
    assert {:ok, %{people: [%{user_id: ^alice}], count: 1}} =
             call(a, %{"action" => "people", "thread" => thread.id})

    assert {:ok, %{count: 1}} = call(a, %{"action" => "list"})
  end

  test "create, get, list, rename, archive, unarchive, people, add, remove, withdraw and leave round-trip",
       %{alice: alice, bob: bob, carol: carol} do
    a = ctx(alice)
    b = ctx(bob)

    assert {:ok, %{id: id, kind: "shared", title: "Plans", status: "active", created_by: ^alice}} =
             call(a, %{"action" => "create", "title" => "Plans"})

    assert {:ok, %{id: ^id, title: "Plans"}} = call(a, %{"action" => "get", "thread" => id})

    assert {:ok, %{thread: ^id, person: %{user_id: ^bob}, state: "added"}} =
             call(a, %{"action" => "add", "thread" => id, "user_id" => bob})

    assert {:ok, %{thread: ^id, state: "added"}} =
             call(a, %{"action" => "add", "thread" => id, "user_id" => carol})

    invited = identifier()

    assert {:ok, %{thread: ^id, person: %{identifier: ^invited}, state: "added"}} =
             call(b, %{"action" => "add", "thread" => id, "identifier" => invited})

    assert {:ok, %{thread: ^id, people: people, count: 4}} =
             call(b, %{"action" => "people", "thread" => id})

    assert [
             %{user_id: ^alice, status: "active"},
             %{user_id: ^bob, status: "active"},
             %{user_id: ^carol, status: "active"},
             %{identifier: ^invited, status: "invited"}
           ] = people

    assert {:ok, %{threads: [%{id: ^id}], count: 1}} = call(b, %{"action" => "list"})

    assert {:ok, %{id: ^id, title: "Trip"}} =
             call(b, %{"action" => "rename", "thread" => id, "title" => "Trip"})

    assert {:ok, %{thread: ^id, identifier: ^invited, state: "withdrawn"}} =
             call(a, %{"action" => "withdraw", "thread" => id, "identifier" => invited})

    assert {:ok, %{thread: ^id, person: %{user_id: ^carol}, state: "removed"}} =
             call(a, %{"action" => "remove", "thread" => id, "user_id" => carol})

    assert {:ok, %{id: ^id, status: "archived"}} =
             call(a, %{"action" => "archive", "thread" => id})

    assert {:ok, %{id: ^id, status: "active"}} =
             call(b, %{"action" => "unarchive", "thread" => id})

    assert {:ok, %{thread: ^id, state: "left", ended: false}} =
             call(a, %{"action" => "leave", "thread" => id})

    assert {:ok, %{thread: ^id, state: "left", ended: true}} =
             call(b, %{"action" => "leave", "thread" => id})

    assert {:ok, %{threads: [], count: 0}} = call(b, %{"action" => "list"})
  end

  test "pair is made for two who share a thread, found again, and names the other person",
       %{alice: alice, bob: bob} do
    a = ctx(alice)
    b = ctx(bob)
    thread = thread!(a)
    {:ok, _} = call(a, %{"action" => "add", "thread" => thread.id, "user_id" => bob})

    assert {:ok, %{kind: "pair", title: nil, with: %{user_id: ^bob}} = pair} =
             call(a, %{"action" => "pair", "user" => bob})

    assert {:ok, %{id: same, with: %{user_id: ^alice}}} =
             call(b, %{"action" => "pair", "user" => alice})

    assert same == pair.id
  end

  test "post, messages and attach round-trip, and attach refuses data that is not base64",
       %{alice: alice, bob: bob} do
    a = ctx(alice)
    b = ctx(bob)
    thread = thread!(a)
    id = thread.id
    {:ok, _} = call(a, %{"action" => "add", "thread" => id, "user_id" => bob})

    assert {:ok, %{seq: 1, author: ^alice, content: "hello", attachments: []}} =
             call(a, %{"action" => "post", "thread" => id, "content" => "hello"})

    assert {:ok, %{seq: 2, author: ^bob, content: "the list", attachments: [ref]} = message} =
             call(b, %{
               "action" => "attach",
               "thread" => id,
               "content" => "the list",
               "files" => [
                 %{
                   "filename" => "list.txt",
                   "media_type" => "text/plain",
                   "data" => Base.encode64("milk, eggs")
                 }
               ]
             })

    assert %{"filename" => "list.txt", "media_type" => "text/plain", "size" => 10} = ref

    assert {:ok, %{bytes: "milk, eggs"}} =
             Sanctum.SharedThreads.attachment(alice, id, message.id, ref["stored_name"])

    assert {:ok, %{thread: ^id, messages: [%{seq: 1}, %{seq: 2}], count: 2}} =
             call(a, %{"action" => "messages", "thread" => id})

    assert {:ok, %{messages: [%{seq: 2}], count: 1}} =
             call(a, %{"action" => "messages", "thread" => id, "after_seq" => 1})

    assert {:ok, %{messages: [%{seq: 1}], count: 1}} =
             call(a, %{"action" => "messages", "thread" => id, "limit" => 1})

    assert {:error, {:invalid_argument, "attach: 'bad.txt' is not base64"}} =
             call(a, %{
               "action" => "attach",
               "thread" => id,
               "files" => [
                 %{"filename" => "bad.txt", "media_type" => "text/plain", "data" => "not base64!"}
               ]
             })

    assert {:ok, %{count: 2}} = call(a, %{"action" => "messages", "thread" => id})
  end

  test "a refusal reaches the caller as its sentence", %{alice: alice, bob: bob, carol: carol} do
    a = ctx(alice)
    c = ctx(carol)
    thread = thread!(a)
    id = thread.id
    {:ok, _} = call(a, %{"action" => "add", "thread" => id, "user_id" => bob})

    # Not seated: the thread is missing.
    assert {:error, {:not_found, "Thread", ^id} = reason} =
             call(c, %{"action" => "get", "thread" => id})

    assert Refusals.render(reason) =~ "not found"

    # A stranger is not paired with, and no one pairs with themselves.
    assert {:error, {:shared_thread, :not_together} = reason} =
             call(c, %{"action" => "pair", "user" => alice})

    assert Refusals.render(reason) ==
             "You can only pair with someone you already share a thread with"

    assert {:error, {:shared_thread, :self} = reason} =
             call(a, %{"action" => "pair", "user" => alice})

    assert Refusals.render(reason) == "A pair is two people — pick someone else"

    # A pair takes no one more.
    {:ok, pair} = call(a, %{"action" => "pair", "user" => bob})

    assert {:error, {:shared_thread, :pair} = reason} =
             call(a, %{"action" => "add", "thread" => pair.id, "user_id" => carol})

    assert Refusals.render(reason) =~ "A pair's two people were set when it opened"

    # An archived thread takes no message.
    {:ok, _} = call(a, %{"action" => "archive", "thread" => id})

    assert {:error, {:shared_thread, :archived} = reason} =
             call(a, %{"action" => "post", "thread" => id, "content" => "late"})

    assert Refusals.render(reason) ==
             "This thread is archived — reopen it to talk or add people"
  end
end
