# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SignInCompleteTest do
  @moduledoc """
  The one sign-in decision both paths take after the door: what cyfr.run
  says about the person, and what follows. A person this server knows
  proceeds whatever the registry answers; a first-time person needs it
  once. Push tokens are cached best-effort; the namespace lands on the
  users row first.
  """
  use ExUnit.Case, async: false

  alias Compendium.Registry.CredentialStore
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

  describe "a first-time person" do
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
               SignIn.complete(user, "github", "gho_access")

      assert ns == "first#{n}"
      assert {:ok, %{namespace: ^ns}} = Users.get(user.id)
      assert {:ok, %{kind: "person"}} = Athanors.get_by_slug("person", ns)

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
               SignIn.complete(user, "github", "gho_access")

      assert ns == "tokenless#{n}"
      assert :not_found = CredentialStore.get(user.id, "registry.test", ns)
    end

    test "with no personal namespace: claim, with a suggestion", %{bypass: bypass} do
      user = person()
      probe_answers(bypass, 200, %{"personal_namespace" => nil, "memberships" => []})

      assert {:needs_claim, suggested} = SignIn.complete(user, "github", "gho_access")
      assert is_binary(suggested)
      assert {:ok, %{namespace: nil}} = Users.get(user.id)
    end

    test "412: legal acceptance first", %{bypass: bypass} do
      user = person()

      probe_answers(bypass, 412, %{
        "errors" => [%{"code" => "POLICY_ACCEPTANCE_REQUIRED"}],
        "required_version" => "2026-01"
      })

      assert {:needs_legal, "2026-01"} = SignIn.complete(user, "github", "gho_access")
    end

    test "401: re-authenticate; 5xx or no answer: unavailable, nothing set up", %{bypass: bypass} do
      user = person()
      probe_answers(bypass, 401, %{"error" => "invalid_access_token"})
      assert {:reauthenticate, :idp_expired} = SignIn.complete(user, "github", "expired")

      probe_answers(bypass, 500, %{"error" => "internal"}, repeat: true)
      assert {:unavailable, :registry_unreachable} = SignIn.complete(user, "github", "gho_access")
      assert {:ok, %{namespace: nil}} = Users.get(user.id)

      assert {:unavailable, :no_access_token} = SignIn.complete(user, "github", nil)
    end

    test "a slug another identity here holds is a conflict, not a sign-in", %{bypass: bypass} do
      _holder = person("taken-slug")
      user = person()

      probe_answers(bypass, 200, %{
        "personal_namespace" => %{"slug" => "taken-slug", "token" => "t"}
      })

      assert {:unavailable, :namespace_conflict} = SignIn.complete(user, "github", "gho_access")
      assert {:ok, %{namespace: nil}} = Users.get(user.id)
    end
  end

  describe "a returning person (namespace recorded here)" do
    test "proceeds on a good probe, refreshing tokens", %{bypass: bypass} do
      user = person("returning-ok")

      probe_answers(bypass, 200, %{
        "personal_namespace" => %{"slug" => "returning-ok", "token" => "cyfr_pt_fresh"}
      })

      assert {:proceed, %{namespace: "returning-ok"}, %{unsynced: [], probe: :ok}} =
               SignIn.complete(user, "github", "gho_access")

      assert {:ok, %{token: "cyfr_pt_fresh"}} =
               CredentialStore.get(user.id, "registry.test", "returning-ok")
    end

    test "proceeds when cyfr.run is down, refuses the token, answers 5xx, or was never asked", %{
      bypass: bypass
    } do
      user = person("returning-offline")

      Bypass.down(bypass)
      assert {:proceed, _, %{probe: :failed}} = SignIn.complete(user, "github", "gho_access")
      Bypass.up(bypass)

      probe_answers(bypass, 401, %{"error" => "invalid_access_token"})
      assert {:proceed, _, %{probe: :invalid_token}} = SignIn.complete(user, "github", "expired")

      probe_answers(bypass, 500, %{"error" => "internal"}, repeat: true)
      assert {:proceed, _, %{probe: :failed}} = SignIn.complete(user, "github", "gho_access")

      assert {:proceed, _, %{probe: :skipped}} = SignIn.complete(user, "github", nil)
      assert {:ok, %{namespace: "returning-offline"}} = Users.get(user.id)
    end

    test "is not held past the budget by a registry that never answers", %{bypass: bypass} do
      user = person("returning-slow")

      Bypass.expect(bypass, "POST", "/v1/identity/probe", fn conn ->
        Process.sleep(2_000)
        json_resp(conn, 200, %{})
      end)

      {us, result} = :timer.tc(fn -> SignIn.complete(user, "github", "gho_access") end)
      assert {:proceed, _, %{probe: :failed}} = result
      assert us < 1_500_000
      # The stranded handler must not fail the test as an unmet expectation.
      Bypass.pass(bypass)
    end

    test "a 412 still reaches them; a registry that forgot them keeps the recorded name", %{
      bypass: bypass
    } do
      user = person("returning-legal")
      probe_answers(bypass, 412, %{"errors" => [%{"code" => "POLICY_ACCEPTANCE_REQUIRED"}]})
      assert {:needs_legal, nil} = SignIn.complete(user, "github", "gho_access")

      probe_answers(bypass, 200, %{"personal_namespace" => nil})
      assert {:proceed, %{namespace: "returning-legal"}, _} = SignIn.complete(user, "github", "x")
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

      assert [] = SignIn.absorb_probe(user.id, body)
      assert {:ok, %{namespace: ns}} = Users.get(user.id)
      assert ns == "absorbed#{n}"

      assert {:ok, %{token: "cyfr_pt_m"}} =
               CredentialStore.get(user.id, "registry.test", "acme.com")
    end
  end
end
