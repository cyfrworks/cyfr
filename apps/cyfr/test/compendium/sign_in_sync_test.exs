# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.SignInSyncTest do
  @moduledoc """
  The courtesy the web sign-in extends after the door: a budgeted probe
  of cyfr.run for the person's publisher namespace and push tokens.
  Whatever the registry answers, the person proceeds; the report says how
  it answered. Push tokens are cached best-effort; a namespace lands on
  the users row first.

  It lives here, not beside `Sanctum.SignIn`, because everything it does
  is the component domain's. The CLI device flow does not probe at all —
  `Sanctum.Auth.DeviceFlow` cannot reach a registry from below, and
  handing the IdP token up to reach one is what its own invariant
  forbids, so a CLI sign-in reports `probe: :skipped` and records nothing.

  What holds that is structural rather than a case here: the device flow
  completes inside `lib/sanctum`, and `Compendium.ReverseSurfaceTest`
  asserts that nothing in `lib/sanctum` names a Compendium module at all.
  A probe reintroduced on that path would have to name one, and would
  fail that roster. There is no end-to-end case because completion needs
  a real IdP round trip, which the suite does not make.
  """
  use ExUnit.Case, async: false

  alias Compendium.Registry.CredentialStore
  alias Compendium.SignInSync
  alias Sanctum.SignIn
  alias Sanctum.Tenancy.{Athanors, Users}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    bypass = Bypass.open()
    original_url = Application.get_env(:cyfr, :registry_url)
    original_scheme = Application.get_env(:cyfr, :registry_scheme)
    original_oci = Application.get_env(:cyfr, :oci_registry_url)

    Application.put_env(:cyfr, :registry_url, "127.0.0.1:#{bypass.port}")
    Application.put_env(:cyfr, :registry_scheme, "http")
    Application.put_env(:cyfr, :oci_registry_url, "registry.test")
    Application.put_env(:cyfr, :returning_probe_ms, 300)

    on_exit(fn ->
      restore = fn key, value ->
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end

      restore.(:registry_url, original_url)
      restore.(:registry_scheme, original_scheme)
      restore.(:oci_registry_url, original_oci)
      Application.delete_env(:cyfr, :returning_probe_ms)
    end)

    {:ok, bypass: bypass}
  end

  defp person(namespace \\ nil) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|c-#{n}",
        provider: "github",
        email: "c#{n}@example.com",
        verified: true
      })

    if namespace do
      {:ok, user} = Users.set_namespace(user, namespace)
      user
    else
      user
    end
  end

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp probe_answers(bypass, status, body, opts \\ []) do
    expect =
      if Keyword.get(opts, :repeat, false), do: &Bypass.expect/4, else: &Bypass.expect_once/4

    expect.(bypass, "POST", "/v1/identity/probe", fn conn -> json_resp(conn, status, body) end)
  end

  describe "a person without a recorded namespace" do
    test "with a personal namespace: it is recorded, the athanor minted, tokens cached", %{
      bypass: bypass
    } do
      user = person()
      n = System.unique_integer([:positive])

      probe_answers(bypass, 200, %{
        "personal_namespace" => %{"slug" => "first#{n}", "token" => "cyfr_pt_personal"},
        "memberships" => [
          %{"slug" => "stripe.com", "token" => "cyfr_pt_stripe", "role" => "admin"}
        ]
      })

      assert {:proceed, %{namespace: ns}, %{unsynced: [], probe: :ok}} =
               SignInSync.complete(user, "github", "gho_access")

      assert ns == "first#{n}"
      assert {:ok, %{namespace: ^ns, personal_athanor_id: pid}} = Users.get(user.id)
      assert {:ok, %{kind: "person", slug: ^ns}} = Athanors.get(pid)

      assert {:ok, %{token: "cyfr_pt_personal"}} =
               CredentialStore.get(user.id, "registry.test", ns)

      assert {:ok, %{role: "admin"}} = CredentialStore.get(user.id, "registry.test", "stripe.com")
    end

    test "with a personal namespace but no token in the body: still recorded, nothing to sync", %{
      bypass: bypass
    } do
      user = person()
      n = System.unique_integer([:positive])
      probe_answers(bypass, 200, %{"personal_namespace" => %{"slug" => "tokenless#{n}"}})

      assert {:proceed, %{namespace: ns}, %{unsynced: [], probe: :ok}} =
               SignInSync.complete(user, "github", "gho_access")

      assert ns == "tokenless#{n}"
      assert :not_found = CredentialStore.get(user.id, "registry.test", ns)
    end

    test "with no personal namespace: signed in, nothing recorded, memberships cached",
         %{bypass: bypass} do
      user = person()

      probe_answers(bypass, 200, %{
        "personal_namespace" => nil,
        "memberships" => [%{"slug" => "acme.com", "token" => "cyfr_pt_m", "role" => "member"}]
      })

      assert {:proceed, %{namespace: nil}, %{unsynced: [], probe: :ok}} =
               SignInSync.complete(user, "github", "gho_access")

      assert {:ok, %{namespace: nil}} = Users.get(user.id)

      assert {:ok, %{token: "cyfr_pt_m"}} =
               CredentialStore.get(user.id, "registry.test", "acme.com")
    end

    test "the claim suggestion is the screen name, else the address's local part" do
      n = System.unique_integer([:positive])

      {:ok, named} =
        Users.upsert_from_provider(%{
          id: "github|https://github.com|sug-#{n}",
          provider: "github",
          email: "alice.smith+work#{n}@example.com",
          verified: true,
          name: "Alice#{n}"
        })

      assert SignIn.suggested_slug(named, "github") == "alice#{n}"

      unnamed = person()
      suggested = SignIn.suggested_slug(unnamed, "github")
      assert is_binary(suggested)
      assert suggested =~ "c"
    end

    test "412: signed in; the policy is owed at publish", %{bypass: bypass} do
      user = person()

      probe_answers(bypass, 412, %{
        "errors" => [%{"code" => "POLICY_ACCEPTANCE_REQUIRED"}],
        "required_version" => "2026-01"
      })

      assert {:proceed, _, %{probe: :legal_required}} =
               SignInSync.complete(user, "github", "gho_access")
    end

    test "401, 5xx and no token each sign the person in with the reason reported", %{
      bypass: bypass
    } do
      user = person()
      probe_answers(bypass, 401, %{"error" => "invalid_access_token"})

      assert {:proceed, _, %{probe: :invalid_token}} =
               SignInSync.complete(user, "github", "expired")

      probe_answers(bypass, 500, %{"error" => "internal"}, repeat: true)
      assert {:proceed, _, %{probe: :failed}} = SignInSync.complete(user, "github", "gho_access")
      assert {:ok, %{namespace: nil}} = Users.get(user.id)

      assert {:proceed, _, %{probe: :skipped}} = SignInSync.complete(user, "github", nil)
    end

    test "a slug another identity here holds is reported, not recorded, and not a refusal", %{
      bypass: bypass
    } do
      _holder = person("taken-slug")
      user = person()

      probe_answers(bypass, 200, %{
        "personal_namespace" => %{"slug" => "taken-slug", "token" => "t"}
      })

      assert {:proceed, _, %{probe: :namespace_conflict}} =
               SignInSync.complete(user, "github", "gho_access")

      assert {:ok, %{namespace: nil}} = Users.get(user.id)
    end

    test "with no registry configured, nothing is asked" do
      Application.put_env(:cyfr, :registry_url, Compendium.RegistryHost.none())
      user = person()

      assert {:proceed, %{namespace: nil}, %{unsynced: [], probe: :skipped}} =
               SignInSync.complete(user, "github", "gho_access")
    end
  end

  describe "a person with a recorded namespace" do
    test "proceeds on a good probe, refreshing tokens", %{bypass: bypass} do
      user = person("returning-ok")

      probe_answers(bypass, 200, %{
        "personal_namespace" => %{"slug" => "returning-ok", "token" => "cyfr_pt_fresh"}
      })

      assert {:proceed, %{namespace: "returning-ok"}, %{unsynced: [], probe: :ok}} =
               SignInSync.complete(user, "github", "gho_access")

      assert {:ok, %{token: "cyfr_pt_fresh"}} =
               CredentialStore.get(user.id, "registry.test", "returning-ok")
    end

    test "proceeds when cyfr.run is down, refuses the token, answers 5xx, or was never asked", %{
      bypass: bypass
    } do
      user = person("returning-offline")

      Bypass.down(bypass)
      assert {:proceed, _, %{probe: :failed}} = SignInSync.complete(user, "github", "gho_access")
      Bypass.up(bypass)

      probe_answers(bypass, 401, %{"error" => "invalid_access_token"})

      assert {:proceed, _, %{probe: :invalid_token}} =
               SignInSync.complete(user, "github", "expired")

      probe_answers(bypass, 500, %{"error" => "internal"}, repeat: true)
      assert {:proceed, _, %{probe: :failed}} = SignInSync.complete(user, "github", "gho_access")

      assert {:proceed, _, %{probe: :skipped}} = SignInSync.complete(user, "github", nil)
      assert {:ok, %{namespace: "returning-offline"}} = Users.get(user.id)
    end

    test "is not held past the budget by a registry that never answers", %{bypass: bypass} do
      user = person("returning-slow")

      Bypass.expect(bypass, "POST", "/v1/identity/probe", fn conn ->
        Process.sleep(2_000)
        json_resp(conn, 200, %{})
      end)

      {us, result} = :timer.tc(fn -> SignInSync.complete(user, "github", "gho_access") end)
      assert {:proceed, _, %{probe: :failed}} = result
      assert us < 1_500_000
      # The stranded handler must not fail the test as an unmet expectation.
      Bypass.pass(bypass)
    end

    test "a 412 is reported; a registry that forgot them keeps the recorded name", %{
      bypass: bypass
    } do
      user = person("returning-legal")
      probe_answers(bypass, 412, %{"errors" => [%{"code" => "POLICY_ACCEPTANCE_REQUIRED"}]})

      assert {:proceed, %{namespace: "returning-legal"}, %{probe: :legal_required}} =
               SignInSync.complete(user, "github", "gho_access")

      probe_answers(bypass, 200, %{"personal_namespace" => nil})

      assert {:proceed, %{namespace: "returning-legal"}, _} =
               SignInSync.complete(user, "github", "x")
    end
  end

  describe "absorb_probe/2" do
    test "records the namespace and caches tokens; unsynced slugs are returned", %{bypass: _} do
      user = person()
      n = System.unique_integer([:positive])

      body = %{
        "personal_namespace" => %{"slug" => "absorbed#{n}", "token" => "cyfr_pt_a"},
        "memberships" => [%{"slug" => "acme.com", "token" => "cyfr_pt_m", "role" => "member"}]
      }

      assert [] = SignInSync.absorb_probe(user.id, body)
      assert {:ok, %{namespace: ns}} = Users.get(user.id)
      assert ns == "absorbed#{n}"

      assert {:ok, %{token: "cyfr_pt_m"}} =
               CredentialStore.get(user.id, "registry.test", "acme.com")
    end
  end
end
