# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.AthanorMemberDoorToolsTest do
  @moduledoc """
  The tenancy verbs through the MCP registry: `athanor.*` and `door.*` —
  who may call them, what they answer, and what they never leak.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Refusals
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Users}
  alias Sanctum.Test.DirectoryServer
  alias Sanctum.Test.RegistryStub

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    n = System.unique_integer([:positive])

    # Local people, each named by their own id and with their own
    # athanor; `ops` carries the platform administrator's mark.
    [alice, bob, ops] =
      for name <- ["alice", "bob", "ops"] do
        {:ok, user} =
          Sanctum.Test.People.linked(%{
            id: "github|https://github.com|#{name}-#{n}",
            provider: "github",
            email: "#{name}#{n}@example.com",
            verified: true
          })

        user.id
      end

    {:ok, _} = Sanctum.TestContext.ensure_platform(ops)

    ctx = fn user_id, athanor_id, opts ->
      Context.build(
        user_id: user_id,
        athanor_id: athanor_id,
        provider: "github",
        permissions: [:*],
        scope: :athanor,
        auth_method: Keyword.get(opts, :auth_method, :oidc),
        authenticated: true,
        platform_admin: Keyword.get(opts, :platform_admin, false)
      )
    end

    {:ok, alice: alice, bob: bob, ops: ops, ctx: ctx, n: n}
  end

  defp call(ctx, tool, args), do: Sanctum.Gate.call_external(tool, ctx, args)

  test "an API key cannot patch an athanor's settings or retry its fill",
       %{alice: alice, ctx: ctx} do
    k = ctx.(alice, personal!(alice).id, auth_method: :api_key)

    for args <- [
          %{"action" => "settings", "settings" => %{"theme" => "dark"}},
          %{"action" => "provision"}
        ] do
      assert {:error, msg} = call(k, "athanor", args)
      assert Refusals.render(msg) =~ "person's act"
    end
  end

  test "door.* is the operator's: refused for a person, open to an admin; a local person is admitted unless denied",
       %{alice: alice, ops: ops, ctx: ctx, n: n} do
    person = ctx.(alice, Sanctum.TestContext.athanor_id(), [])

    assert {:error, %Prima.Refusal{stage: :admission, reason: :platform_admin_required}} =
             call(person, "door", %{"action" => "list"})

    admin = ctx.(ops, Sanctum.TestContext.athanor_id(), platform_admin: true)
    assert {:ok, %{entries: []}} = call(admin, "door", %{"action" => "list"})

    # A local person needs no entry: their admission was the admitting act.
    {:ok, carol} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|carol-#{n}",
        provider: "github",
        email: "carol#{n}@example.com",
        verified: true
      })

    assert {:ok, :allowed} = Sanctum.Door.admit_person(carol)

    # Allows name an identifier or `*`, never a person or an address.
    identifier = "per_" <> Prima.Digest.sha256_hex("door-op-#{n}")

    assert {:ok, %{kind: "identifier", effect: "allow", note: "friend"}} =
             call(admin, "door", %{"action" => "allow", "value" => identifier, "note" => "friend"})

    assert {:ok, :allowed} = Sanctum.Door.admit_identifier(identifier)

    assert {:ok, %{kind: "wildcard"}} =
             call(admin, "door", %{"action" => "allow", "value" => "*"})

    for value <- [carol.id, "carol#{n}@example.com", "github|https://github.com|carol-#{n}"] do
      assert {:error, {:invalid_argument, _}} =
               call(admin, "door", %{"action" => "allow", "value" => value}),
             "door.allow took #{value}"
    end

    # A deny names a person and ejects them, sticky against `*`.
    assert {:ok, %{kind: "person", effect: "deny", ejected: 1, id: deny_id}} =
             call(admin, "door", %{"action" => "deny", "value" => carol.id})

    assert {:error, :denied} = Sanctum.Door.admit_person(carol)
    assert {:ok, %{status: "denied"}} = Users.get(carol.id)

    # `*` is not denied, and an address is not a person.
    for value <- ["*", "carol#{n}@example.com"] do
      assert {:error, {:invalid_argument, _}} =
               call(admin, "door", %{"action" => "deny", "value" => value}),
             "door.deny took #{value}"
    end

    # The platform administrator is never denied.
    assert {:error, msg} = call(admin, "door", %{"action" => "deny", "value" => ops})
    assert Refusals.render(msg) =~ "platform administrator"
    assert {:ok, :allowed} = Sanctum.Door.admit_person(%{id: ops})

    # Removing the deny lets the person back: nobody is left denied with no
    # entry to say why.
    assert {:ok, %{removed: true, restored: 1}} =
             call(admin, "door", %{"action" => "remove", "id" => deny_id})

    assert {:ok, %{status: "active"}} = Users.get(carol.id)
    assert {:ok, :allowed} = Sanctum.Door.admit_person(carol)
  end

  # A session the door's verdict issued to `user_id`.
  defp session_for(user_id, email) do
    ctx =
      Context.build(
        user_id: user_id,
        email: email,
        provider: "github",
        authenticated: true,
        permissions: [:read]
      )

    {:ok, session} =
      Sanctum.Session.create(ctx, generation_snapshot: Sanctum.TestContext.snapshot!(ctx))

    session
  end

  test "door.remove of an allow through the gate ejects the remote person it admitted, and only them",
       %{alice: alice, ops: ops, ctx: ctx, n: n} do
    admin = ctx.(ops, Sanctum.TestContext.athanor_id(), platform_admin: true)

    # Two remote people, their heads fresh at this home as the CYFR
    # sign-in leaves them, so the door issued each a session.
    tls = DirectoryServer.tls()
    DirectoryServer.listen!()
    DirectoryServer.seam!(tls)
    directory = DirectoryServer.start!(tls)

    [{dave, dave_identifier}, {erin, erin_identifier}] =
      for _name <- ["dave", "erin"] do
        identity = DirectoryServer.identity!(directory.dir, directory.url)

        {:ok, user} =
          Sanctum.Test.People.remote(
            %{
              id: Sanctum.Auth.Identity.cyfr_key(identity.url, identity.identifier),
              provider: "cyfr"
            },
            %{identifier: identity.identifier, directory_url: identity.url}
          )

        _head = DirectoryServer.cached!(identity)
        {user, identity.identifier}
      end

    assert {:ok, %{effect: "allow", id: dave_allow}} =
             call(admin, "door", %{"action" => "allow", "value" => dave_identifier})

    assert {:ok, %{effect: "allow"}} =
             call(admin, "door", %{"action" => "allow", "value" => erin_identifier})

    # What the door issued: a session for each; and a local person's
    # session, which no allow issued.
    dave_session = session_for(dave.id, nil)
    erin_session = session_for(erin.id, nil)
    alice_session = session_for(alice, "alice#{n}@example.com")

    assert {:ok, _} = Sanctum.Session.get(dave_session.token)

    assert {:ok, %{id: ^dave_allow, removed: true, ejected: 1}} =
             call(admin, "door", %{"action" => "remove", "id" => dave_allow})

    assert {:error, :not_allowed} = Sanctum.Door.admit_person(dave)
    assert {:error, :invalid_session} = Sanctum.Session.get(dave_session.token)

    # The person another entry still admits keeps what they hold, and a
    # local person needs no entry at all.
    assert {:ok, :allowed} = Sanctum.Door.admit_person(erin)
    assert {:ok, _} = Sanctum.Session.get(erin_session.token)
    assert {:ok, :allowed} = Sanctum.Door.admit_person(%{id: alice})
    assert {:ok, _} = Sanctum.Session.get(alice_session.token)

    # Closing a door is not denying a person.
    assert {:ok, %{status: "active"}} = Users.get(dave.id)
  end

  test "door.* allows, denies, lists and resolves a person identifier, which the cyfr door is judged by",
       %{ops: ops, ctx: ctx, n: n} do
    admin = ctx.(ops, Sanctum.TestContext.athanor_id(), platform_admin: true)
    identifier = "per_" <> Prima.Digest.sha256_hex("door-tools-#{n}")

    # An unadmitted remote newcomer waits for the operator as an identifier.
    assert {:error, {:door, :not_allowed}} = Sanctum.Door.sign_in_identifier(identifier)

    assert {:ok, %{requests: requests}} = call(admin, "door", %{"action" => "requests"})

    assert [%{id: request_id, kind: "identifier"}] =
             Enum.filter(requests, &(&1.value == identifier))

    assert {:ok, %{kind: "identifier", status: "allowed"}} =
             call(admin, "door", %{
               "action" => "resolve",
               "id" => request_id,
               "decision" => "allow"
             })

    assert {:ok, :allowed} = Sanctum.Door.admit_identifier(identifier)

    # Its shape names its kind; a value of no kind is refused.
    other = "per_" <> Prima.Digest.sha256_hex("door-tools-other-#{n}")

    assert {:ok, %{kind: "identifier", effect: "allow"}} =
             call(admin, "door", %{"action" => "allow", "value" => other})

    assert {:error, {:invalid_argument, message}} =
             call(admin, "door", %{"action" => "allow", "value" => "per_x"})

    assert message =~ "person identifier"

    # A deny by identifier ejects the remote person the door admitted under
    # it, and is sticky against `*`.
    user = remote!(identifier)
    assert {:ok, _} = call(admin, "door", %{"action" => "allow", "value" => "*"})
    assert {:ok, :allowed} = Sanctum.Door.admit_person(user)

    assert {:ok, %{effect: "deny", kind: "identifier", ejected: 1}} =
             call(admin, "door", %{"action" => "deny", "value" => identifier})

    assert {:error, :denied} = Sanctum.Door.admit_person(user)
    assert {:error, :denied} = Sanctum.Door.admit_identifier(identifier)
    assert {:ok, %{status: "denied"}} = Users.get(user.id)

    assert {:ok, %{entries: entries}} = call(admin, "door", %{"action" => "list"})
    assert Enum.any?(entries, &(&1.kind == "identifier" and &1.value == identifier))

    # Allowing the identifier again restores the person.
    assert {:ok, %{effect: "allow", restored: 1}} =
             call(admin, "door", %{"action" => "allow", "value" => identifier})

    assert {:ok, %{status: "active"}} = Users.get(user.id)
    assert {:ok, :allowed} = Sanctum.Door.admit_person(user)
  end

  test "door.deny of an identifier no person here holds withdraws its invitations from every shared thread",
       %{alice: alice, ops: ops, ctx: ctx, n: n} do
    admin = ctx.(ops, Sanctum.TestContext.athanor_id(), platform_admin: true)
    identifier = "per_" <> Prima.Digest.sha256_hex("door-invited-#{n}")

    {:ok, %{id: plans}} = Sanctum.SharedThreads.create(alice, "Plans #{n}")
    {:ok, %{id: trip}} = Sanctum.SharedThreads.create(alice, "Trip #{n}")

    for thread <- [plans, trip] do
      assert {:ok, :added} = Sanctum.SharedThreads.add(alice, thread, identifier: identifier)
      assert {:ok, people} = Sanctum.SharedThreads.people(alice, thread)
      assert %{status: "invited"} = Enum.find(people, &(&1[:identifier] == identifier))
    end

    assert {:ok, %{effect: "deny", kind: "identifier", ejected: 0, invites_withdrawn: 2}} =
             call(admin, "door", %{"action" => "deny", "value" => identifier})

    # The seat does not outlive the eject: each thread's people no longer
    # name the identifier, and alice still sits in both.
    for thread <- [plans, trip] do
      assert {:ok, people} = Sanctum.SharedThreads.people(alice, thread)
      refute Enum.any?(people, &(&1[:identifier] == identifier))
      assert Enum.any?(people, &(&1[:user_id] == alice))
    end
  end

  test "door.allow and door.deny take a handle: the entry keeps the identifier it names, labelled with the handle",
       %{ops: ops, ctx: ctx, n: n} do
    admin = ctx.(ops, Sanctum.TestContext.athanor_id(), platform_admin: true)
    first = "per_" <> Prima.Digest.sha256_hex("door-handle-#{n}")
    second = "per_" <> Prima.Digest.sha256_hex("door-handle-second-#{n}")
    RegistryStub.handles!(%{"alice" => first, "bob" => second})

    assert {:ok, %{kind: "identifier", effect: "allow", value: ^first, label: "alice"}} =
             call(admin, "door", %{"action" => "allow", "value" => "@alice"})

    assert {:ok, :allowed} = Sanctum.Door.admit_identifier(first)

    assert {:ok, %{kind: "identifier", effect: "deny", value: ^second, label: "bob"}} =
             call(admin, "door", %{"action" => "deny", "value" => "@bob"})

    # The list shows the label where there is one, and no label key where
    # there is none.
    assert {:ok, _} = call(admin, "door", %{"action" => "allow", "value" => "*"})
    assert {:ok, %{entries: entries}} = call(admin, "door", %{"action" => "list"})
    assert %{label: "alice"} = Enum.find(entries, &(&1.value == first))
    assert %{label: "bob"} = Enum.find(entries, &(&1.value == second))
    refute Map.has_key?(Enum.find(entries, &(&1.value == "*")), :label)

    # The registry gives the handle to the second identifier: the entry
    # still names the first, and admits only them.
    RegistryStub.handles!(%{"alice" => second})
    assert {:ok, %{entries: entries}} = call(admin, "door", %{"action" => "list"})
    assert [%{value: ^first}] = Enum.filter(entries, &(&1[:label] == "alice"))
    assert {:ok, :allowed} = Sanctum.Door.admit_identifier(first)
    assert {:error, :denied} = Sanctum.Door.admit_identifier(second)
  end

  test "a handle the registry does not resolve is refused through the gate in its own sentence, and nothing is written",
       %{ops: ops, ctx: ctx} do
    admin = ctx.(ops, Sanctum.TestContext.athanor_id(), platform_admin: true)
    before = Sanctum.Door.Store.list()

    RegistryStub.handles!(%{"alice" => :close})

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, reason} = call(admin, "door", %{"action" => "allow", "value" => "@alice"})
      assert %{reason: :registry_unavailable, class: :unavailable} = Refusals.classify(reason)
    end)

    RegistryStub.handles!(%{})
    assert {:error, reason} = call(admin, "door", %{"action" => "deny", "value" => "@nobody"})
    assert Refusals.render(reason) == "No one holds that handle at the registry."

    assert {:error, {:invalid_argument, message}} =
             call(admin, "door", %{"action" => "allow", "value" => "@Not-A-Handle"})

    assert message =~ "not a handle"

    Application.put_env(:sanctum, :registry_url, "none")
    assert {:error, reason} = call(admin, "door", %{"action" => "allow", "value" => "@alice"})
    assert %{reason: :no_registry} = Refusals.classify(reason)

    assert Sanctum.Door.Store.list() == before
  end

  test "athanor.get answers a caller not its person the same for an open, an archived and a missing athanor; its person hears archived",
       %{alice: alice, bob: bob, ctx: ctx, n: n} do
    open = personal!(bob)

    {:ok, carol} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|carol-#{n}",
        provider: "github",
        email: "carol#{n}@example.com",
        verified: true
      })

    closed = personal!(carol.id)
    %{status: "archived"} = Sanctum.TestContext.archive!(closed.id)
    missing = Prima.UUID7.generate_id("ath")

    a = ctx.(alice, personal!(alice).id, [])

    # The refusal names what the caller named and nothing else, so with
    # the name taken out the three answers are one.
    for id <- [open.id, closed.id, missing] do
      assert {:error, {:not_found, "Athanor", ^id}} =
               call(a, "athanor", %{"action" => "get", "athanor" => id}),
             "athanor.get told a caller not its person something of #{id}"
    end

    # Its person hears that it is archived, and still reads it.
    c = ctx.(carol.id, closed.id, [])

    assert {:ok, %{status: "archived"}} =
             call(c, "athanor", %{"action" => "get", "athanor" => closed.id})

    assert {:error, {:invalid_argument, "That athanor is archived"}} =
             call(c, "athanor", %{
               "action" => "settings",
               "settings" => %{"theme" => "dark"},
               "athanor" => closed.id
             })
  end

  test "an archived athanor refuses every mutation by id, for its person and for an operator; its person reads it, and an operator not its person is answered as for a missing athanor",
       %{alice: alice, ops: ops, ctx: ctx} do
    personal = personal!(alice)
    %{status: "archived"} = Sanctum.TestContext.archive!(personal.id)
    a = ctx.(alice, personal.id, [])
    operator = ctx.(ops, Sanctum.TestContext.athanor_id(), platform_admin: true)

    for {who, refused} <- [{a, "archived"}, {operator, "not found"}],
        args <- [
          %{"action" => "settings", "settings" => %{"aqua" => %{"answer_mode" => "all"}}},
          %{"action" => "provision"}
        ] do
      assert {:error, msg} = call(who, "athanor", Map.put(args, "athanor", personal.id))

      assert Refusals.render(msg) =~ refused,
             "athanor.#{args["action"]} ran on an archived athanor"
    end

    {:ok, unchanged} = Athanors.get(personal.id)
    assert Athanors.settings(unchanged) == Athanors.settings(personal)

    # Reads still answer its person, whole.
    assert {:ok, %{status: "archived"}} =
             call(a, "athanor", %{"action" => "get", "athanor" => personal.id})

    # An operator who is not its person hears nothing of it, not even that
    # it is archived: their capability is over the instance, not an
    # athanor, and the read answers as it does for an athanor that does not
    # exist.
    missing = "ath_" <> Prima.UUID7.generate()

    for named <- [personal.id, missing] do
      assert {:error, {:not_found, "Athanor", ^named}} =
               call(operator, "athanor", %{"action" => "get", "athanor" => named})
    end
  end

  test "a denied person's own athanor is archived by deny at the door and reopened by removing the deny",
       %{alice: alice, ops: ops, ctx: ctx} do
    personal = personal!(alice)

    # The door verbs are the operator's platform-scope acts: they run under
    # the server's own transitions and need no standing in the athanor they
    # close and reopen.
    operator = ctx.(ops, Sanctum.TestContext.athanor_id(), platform_admin: true)

    assert {:ok, %{effect: "deny", ejected: 1, id: deny_id}} =
             call(operator, "door", %{"action" => "deny", "value" => alice})

    assert {:ok, %{status: "denied"}} = Users.get(alice)
    assert {:ok, %{status: "archived"}} = Athanors.get(personal.id)

    # The athanor is not the operator's, so get refuses them as it refuses
    # anyone else, as for an athanor that does not exist.
    assert {:error, msg} =
             call(operator, "athanor", %{"action" => "get", "athanor" => personal.id})

    assert Refusals.render(msg) =~ "not found"

    assert {:ok, %{status: "archived"}} = Athanors.get(personal.id)

    # Removing the deny at the door reopens it, and she focuses it again.
    assert {:ok, %{removed: true, restored: 1}} =
             call(operator, "door", %{"action" => "remove", "id" => deny_id})

    assert {:ok, %{status: "active"}} = Users.get(alice)
    assert {:ok, %{status: "active"}} = Athanors.get(personal.id)
    assert {:ok, %{athanor_id: focused}} = Context.focus(ctx.(alice, nil, []), personal.id)
    assert focused == personal.id
  end

  describe "Sanctum.Providers.Athanor.resolve/3 returns a focused context" do
    # Every downstream act (provisioning above all) must run at
    # `scope: :athanor` with the resolved athanor bound — a platform
    # context's wider scope stops at resolve, not in the handler, and only
    # the athanor's person gets it there.
    test "a person's context is rebound to the athanor they name",
         %{alice: alice, ctx: ctx} do
      a = ctx.(alice, Sanctum.TestContext.athanor_id(), [])
      %{id: athanor_id} = personal!(alice)

      assert {:ok, athanor, focused} =
               Sanctum.Providers.Athanor.resolve(a, %{"athanor" => athanor_id})

      assert athanor.id == athanor_id
      assert focused.athanor_id == athanor_id
      assert focused.scope == :athanor
    end

    test "a platform context narrows to its person's own athanor, and opens no other",
         %{alice: alice, ops: ops} do
      %{id: theirs} = personal!(alice)

      operator =
        Sanctum.TestContext.platform(
          user_id: ops,
          permissions: [:*],
          auth_method: :oidc,
          platform_admin: true
        )

      # Another person's: the platform scope and the capability open nothing.
      assert {:error, {:not_found, "Athanor", id}} =
               Sanctum.Providers.Athanor.resolve(operator, %{"athanor" => theirs})

      assert id == theirs

      %{id: athanor_id} = personal!(ops)

      assert {:ok, athanor, focused} =
               Sanctum.Providers.Athanor.resolve(operator, %{"athanor" => athanor_id})

      assert athanor.id == athanor_id
      assert focused.athanor_id == athanor_id
      assert focused.scope == :athanor
    end

    test "an athanor the store cannot read is unavailable, never not found",
         %{alice: alice, ctx: ctx} do
      a = ctx.(alice, Sanctum.TestContext.athanor_id(), [])
      %{id: athanor_id} = personal!(alice)

      Arca.Repo.query!("ALTER TABLE athanors RENAME TO athanors_unavailable")

      assert {:error, {:unavailable, "Storage"}} =
               Sanctum.Providers.Athanor.resolve(a, %{"athanor" => athanor_id})
    end
  end

  # The person's own athanor, made with them by their admission.
  defp personal!(user_id) do
    {:ok, athanor} = Athanors.get_by_owner(user_id)
    athanor
  end

  # A person whose keys another CYFR holds, admitted here under the CYFR
  # sign-in identity `identifier` names.
  defp remote!(identifier) do
    {:ok, user} =
      Sanctum.Test.People.remote(
        %{
          id: Sanctum.Auth.Identity.cyfr_key("https://dir.example", identifier),
          provider: "cyfr"
        },
        %{identifier: identifier, directory_url: "https://dir.example"}
      )

    user
  end
end
