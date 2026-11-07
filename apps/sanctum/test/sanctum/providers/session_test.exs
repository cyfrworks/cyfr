# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.SessionTest do
  @moduledoc """
  `session.name`: the person types the name their account holds at
  cyfr.run, and it is recorded as their name here once the registry's
  answer for it names their own account (`Sanctum.SignIn.record_name/2`).
  A name of another account, of none, one the registry cannot be asked
  about, a spelling that is no name, and one another person here holds
  are each refused in a sentence the person reads, and nothing is
  recorded. A name recorded before is kept.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Providers.Session
  alias Sanctum.Tenancy.Users
  alias Sanctum.Test.{DirectoryServer, RegistryStub}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|session-name-#{n}",
        provider: "github"
      })

    %{account: account, dir: dir} = DirectoryServer.member!(user.id)

    ctx =
      Sanctum.Context.build(
        user_id: user.id,
        athanor_id: Sanctum.Test.People.athanor!(user).id,
        provider: "passkey",
        auth_method: :oidc,
        authenticated: true,
        permissions: Sanctum.Context.person_permissions()
      )

    %{user: user, ctx: ctx, account: account, dir: dir}
  end

  defp name(ctx, typed), do: Session.handle(ctx, %{"action" => "name", "name" => typed})

  defp recorded(user) do
    {:ok, %{namespace: namespace}} = Users.get(user.id)
    namespace
  end

  test "records the name the registry says the person's account holds, as typed with its @",
       %{ctx: ctx, user: user, account: account, dir: dir} do
    RegistryStub.handles!(%{"mira" => account.identifier}, dir.url)

    assert {:ok, %{name: "mira"}} = name(ctx, " @Mira ")
    assert recorded(user) == "mira"
    assert_received {:registry_request, %{method: "GET", path: "/v1/handles/mira"}}
  end

  test "refuses another account's name, no account's, and one the registry cannot answer, recording nothing",
       %{ctx: ctx, user: user, dir: dir} do
    stranger = DirectoryServer.account!(dir.dir, dir.url)
    RegistryStub.handles!(%{"taken" => stranger.identifier, "lost" => :close}, dir.url)

    for {typed, reason, class, sentence} <- [
          {"taken", :name_not_theirs, :forbidden, "@taken is another account's name, not yours"},
          {"unheld", :name_unheld, :not_found,
           "No account holds @unheld at cyfr.run: type the name you chose when you made your account"},
          {"lost", :registry_unavailable, :unavailable,
           "cyfr.run could not check that name just now; try again shortly"}
        ] do
      assert {:error, %Prima.Refusal{reason: ^reason, class: ^class, message: ^sentence}} =
               name(ctx, typed),
             typed

      assert recorded(user) == nil, typed
    end
  end

  test "a spelling that is no name is refused before the registry is asked", %{ctx: ctx, dir: dir} do
    RegistryStub.handles!(%{}, dir.url)

    assert {:error, %Prima.Refusal{reason: :invalid_name, class: :invalid_argument}} =
             name(ctx, "not a name!")

    refute_received {:registry_request, _}
  end

  test "with no registry, nothing can be checked", %{ctx: ctx, user: user} do
    Prima.Test.Env.put_app_env(:sanctum, :registry_url, "none")

    assert {:error, %Prima.Refusal{reason: :no_registry, class: :setup_required}} =
             name(ctx, "mira")

    assert recorded(user) == nil
  end

  test "a name another person here holds is refused, and a name recorded before is kept",
       %{ctx: ctx, user: user, account: account, dir: dir} do
    RegistryStub.handles!(%{"held" => account.identifier, "mine" => account.identifier}, dir.url)
    n = System.unique_integer([:positive])

    {:ok, other} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|holder-#{n}",
        provider: "github"
      })

    {:ok, _other} = Users.set_namespace(other, "held")

    assert {:error,
            %Prima.Refusal{
              reason: :namespace_owned_by_another_identity,
              class: :conflict,
              message: "Another person on this CYFR holds @held: ask whoever runs this CYFR"
            }} = name(ctx, "held")

    assert recorded(user) == nil

    {:ok, row} = Users.get(user.id)
    {:ok, _row} = Users.set_namespace(row, "earlier")
    assert {:ok, %{name: "earlier"}} = name(ctx, "mine")
    assert recorded(user) == "earlier"
  end

  test "is a person's own act, through an interactive surface", %{ctx: ctx} do
    assert {:error, :unauthenticated} = name(%{ctx | authenticated: false}, "mira")

    op =
      Enum.find(Session.definition().operations, &(&1.action == "name")) ||
        flunk("session.name is not declared")

    assert %Prima.Operation{kind: :write, consent: :interactive, planes: [:external]} = op
  end
end
