# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.AccountsTest do
  @moduledoc """
  The accounts an app's own calls may name, read from its stored head:
  one account's entry on the ingress of the profile a run would root at
  (`Sanctum.Consent.Accounts.resolve/4`), and the apps whose default
  profile binds named accounts, with their names
  (`Sanctum.Consent.Accounts.list/1`). A name not bound, and a source
  with nothing to root at, is a grant to make; a damaged row is its own
  refusal, never a grant to make.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Sanctum.Consent.Accounts
  alias Sanctum.Consent.{Commit, Plan}

  @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "consent_accounts_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local(:prism)}
  end

  # An app of the person's own whose own calls carry one credential need.
  defp app!(ctx, name) do
    manifest = %{
      "name" => name,
      "version" => "1.0.0",
      "type" => "reagent",
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:example.com",
          "reason" => "to call the example API",
          "fields" => ["KEY"]
        }
      },
      "caps" => %{"egress" => %{"domains" => ["api.example.com"]}}
    }

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: name,
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(manifest)
      })

    "reagent:local." <> name
  end

  defp entry!(ctx, name) do
    {:ok, view} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: name,
        kind: "api_key",
        provider_hint: "example.com",
        fields: %{"KEY" => "k-#{name}"},
        destination: %{"hosts" => ["api.example.com"]},
        disclose: true
      })

    view
  end

  # The app's grant under `label`, binding `bindings` on its own calls.
  defp grant!(ctx, ref, bindings, label \\ "default") do
    {:ok, plan} = Plan.plan(ctx, %{ref: ref, label: label})
    decisions = %{ref: ref, label: label, bindings: bindings}
    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, %{profile_id: profile_id}} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    profile_id
  end

  defp named!(ctx, ref, names) do
    default = entry!(ctx, "#{ref} default")

    accounts =
      Map.new(names, fn name -> {name, entry!(ctx, "#{ref} #{name}")} end)

    bindings =
      [%{need: "api_key", entry_id: default.id}] ++
        Enum.map(accounts, fn {name, entry} ->
          %{need: "api_key", name: name, entry_id: entry.id}
        end)

    profile_id = grant!(ctx, ref, bindings)
    %{profile_id: profile_id, default: default, accounts: accounts}
  end

  describe "resolve/4" do
    test "a name the app's own profile binds resolves to its entry, by any version of the reference",
         %{ctx: ctx} do
      ref = app!(ctx, "acct-one")
      %{accounts: %{"Work" => work, "Home" => home}} = named!(ctx, ref, ["Work", "Home"])

      assert {:ok, %{entry_id: work.id, name: "Work"}} ==
               Accounts.resolve(ctx, :default, ref, "Work")

      assert {:ok, %{entry_id: home.id, name: "Home"}} ==
               Accounts.resolve(ctx, :default, ref <> ":1.0.0", "Home")

      assert {:ok, %{entry_id: work.id, name: "Work"}} ==
               Accounts.resolve(ctx, {:label, "default"}, ref, "Work")
    end

    test "a name in another case is the same account, answered by the name its binding stores",
         %{ctx: ctx} do
      ref = app!(ctx, "acct-case")
      %{accounts: %{"Work" => work}} = named!(ctx, ref, ["Work"])

      for spelled <- ["work", "WORK", "wOrK"] do
        assert {:ok, %{entry_id: work.id, name: "Work"}} ==
                 Accounts.resolve(ctx, :default, ref, spelled),
               "#{inspect(spelled)} did not resolve to Work"
      end
    end

    test "a name the ingress does not bind, or no account at all, is a grant to make", %{ctx: ctx} do
      ref = app!(ctx, "acct-two")
      %{default: default} = named!(ctx, ref, ["Work"])

      # The default slot is no account's name, nor is an entry's id.
      for name <- ["Home", "Works", "default", default.id] do
        assert {:error, :connection_not_granted} =
                 Accounts.resolve(ctx, :default, ref, name),
               "#{inspect(name)} resolved"
      end

      # An app with no profile, and one whose profile was revoked, binds none.
      bare = app!(ctx, "acct-bare")

      assert {:error, :connection_not_granted} =
               Accounts.resolve(ctx, :default, bare, "Work")

      {:ok, _revoked} = Sanctum.Consent.revoke_source(ctx, ref)

      assert {:error, :connection_not_granted} =
               Accounts.resolve(ctx, :default, ref, "Work")
    end

    test "a selection that cannot be made, and a damaged row, are their own refusal", %{ctx: ctx} do
      ref = app!(ctx, "acct-three")
      %{profile_id: profile_id} = named!(ctx, ref, ["Work"])

      assert {:error, {:not_found, "elsewhere"}} =
               Accounts.resolve(ctx, {:label, "elsewhere"}, ref, "Work")

      assert {:error, {:invalid_reference, _}} =
               Accounts.resolve(ctx, :default, "not a reference", "Work")

      # A second active owner profile makes the default selection ambiguous.
      second = entry!(ctx, "acct-three second")
      grant!(ctx, ref, [%{need: "api_key", entry_id: second.id}], "other")

      assert {:error, {:ambiguous, _ids}} = Accounts.resolve(ctx, :default, ref, "Work")

      # A profile row whose status no writer produces is damage, not an absence.
      {1, _} =
        Arca.Repo.update_all(
          from(p in Arca.Schemas.Profile,
            where: p.athanor_id == ^ctx.athanor_id and p.id == ^profile_id
          ),
          set: [status: "sideways"]
        )

      assert {:error, {:corrupt, {:profile, ^profile_id}}} =
               Accounts.resolve(ctx, {:label, "other"}, ref, "Work")
    end

    # The app's own head reads as a run's root reads it: the same stored
    # state answers the same refusal here as at admission, the loader's one
    # reading of it (`Sanctum.Consent.Loader.damage_refusal/3`), and never
    # a grant to make over a profile that exists.
    test "a head stored damaged, in each way a run's root reads it so, is the damaged head",
         %{ctx: ctx} do
      ref = app!(ctx, "acct-damaged")
      %{profile_id: profile_id} = named!(ctx, ref, ["Work"])

      for changes <- [
            # stored outside the closed vocabulary
            [scope: "sideways"],
            # bytes that fail their digest
            [blob_digest: "sha256:" <> String.duplicate("0", 64)],
            # bytes that do not parse, under their own digest
            [resolved_policy: "not a blob", blob_digest: Prima.JCS.hash_binary("not a blob")],
            # a revision pinning a version its scope does not
            [pinned_version: "0.1.0"]
          ] do
        stored = stored_head(ctx, profile_id, Keyword.keys(changes))
        :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, profile_id, changes)

        assert {changes, Accounts.resolve(ctx, :default, ref, "Work")} ==
                 {changes, {:error, {:head_corrupt, profile_id}}}

        :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, profile_id, stored)
        assert {:ok, %{name: "Work"}} = Accounts.resolve(ctx, :default, ref, "Work")
      end
    end

    test "an active profile with no head is the damaged head, never a grant to make",
         %{ctx: ctx} do
      ref = app!(ctx, "acct-headless")
      %{profile_id: profile_id} = named!(ctx, ref, ["Work"])
      set_profile!(ctx, profile_id, head_consent_id: nil)

      assert Accounts.resolve(ctx, :default, ref, "Work") ==
               {:error, {:head_corrupt, profile_id}}
    end

    # Every grant a commit writes holds its source's ingress, so a head
    # whose grant holds none is damage, as the loader's `missing_ingress`.
    test "a head whose grant holds no ingress for the app is the damaged head, never a grant " <>
           "to make",
         %{ctx: ctx} do
      ref = app!(ctx, "acct-no-ingress")
      %{profile_id: profile_id} = named!(ctx, ref, ["Work"])
      {:ok, head} = Sanctum.Consent.head_consent(ctx, profile_id)

      # The ingress goes with the rows of what it bound, so the head's own
      # checks still pass and only the ingress is missing.
      Arca.Repo.delete_all(
        from(r in Arca.Schemas.ConsentVaultRef,
          where: r.athanor_id == ^ctx.athanor_id and r.consent_id == ^head.id
        )
      )

      policy =
        head.resolved_policy
        |> Jason.decode!()
        |> update_in(["nodes", ref, "edges"], &Map.delete(&1, "@ingress"))
        |> Jason.encode!()

      :ok =
        Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, profile_id,
          resolved_policy: policy,
          blob_digest: Prima.JCS.hash_binary(policy)
        )

      {:ok, head} = Sanctum.Consent.head_consent(ctx, profile_id)
      assert {:ok, _blob} = Sanctum.Consent.Loader.admitted_blob(ctx, %{id: profile_id}, head)

      assert Accounts.resolve(ctx, :default, ref, "Work") ==
               {:error, {:head_corrupt, profile_id}}
    end

    @tag :capture_log
    test "a head the store cannot answer is the unanswered head, never damage or a grant to make",
         %{ctx: ctx} do
      ref = app!(ctx, "acct-unanswered")
      %{profile_id: profile_id} = named!(ctx, ref, ["Work"])

      Arca.Repo.query!("ALTER TABLE consents RENAME TO consents_unavailable")
      answer = Accounts.resolve(ctx, :default, ref, "Work")
      Arca.Repo.query!("ALTER TABLE consents_unavailable RENAME TO consents")

      assert answer == {:error, {:head_unavailable, profile_id}}
    end
  end

  # The columns `keys` of the profile's head row, as stored.
  defp stored_head(ctx, profile_id, keys) do
    {:ok, profile} = Arca.ProfileStorage.get(Sanctum.Context.actor(ctx), profile_id)

    Arca.Repo.one!(
      from(c in Arca.Schemas.Consent,
        where: c.athanor_id == ^ctx.athanor_id and c.id == ^profile.head_consent_id,
        select: map(c, ^keys)
      )
    )
    |> Map.to_list()
  end

  # A profile row written as no writer of the table would.
  defp set_profile!(ctx, id, changes) do
    {1, _} =
      Arca.Repo.update_all(
        from(p in Arca.Schemas.Profile, where: p.athanor_id == ^ctx.athanor_id and p.id == ^id),
        set: changes
      )
  end

  describe "list/1" do
    test "lists each app whose default profile binds named accounts, with their names, by reference",
         %{ctx: ctx} do
      zeta = app!(ctx, "acct-zeta")
      alpha = app!(ctx, "acct-alpha")
      plain = app!(ctx, "acct-plain")
      twice = app!(ctx, "acct-twice")

      named!(ctx, zeta, ["Work", "Home"])
      named!(ctx, alpha, ["Personal"])
      grant!(ctx, plain, [%{need: "api_key", entry_id: entry!(ctx, "plain").id}])

      # Two active owner profiles: no default to name an account of.
      named!(ctx, twice, ["Work"])
      grant!(ctx, twice, [%{need: "api_key", entry_id: entry!(ctx, "twice other").id}], "other")

      assert {:ok, accounts, false} = Accounts.list(ctx)
      assert accounts == [{alpha, ["Personal"]}, {zeta, ["Home", "Work"]}]
    end

    test "a head that cannot be read is left out, and the rest are listed", %{ctx: ctx} do
      good = app!(ctx, "acct-good")
      bad = app!(ctx, "acct-bad")
      named!(ctx, good, ["Work"])
      %{profile_id: bad_profile} = named!(ctx, bad, ["Work"])

      # A head whose blob no longer matches its digest is refused by the loader.
      Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, bad_profile,
        blob_digest: "sha256:" <> String.duplicate("0", 64)
      )

      assert {:ok, [{^good, ["Work"]}], false} = Accounts.list(ctx)

      # The damaged app's account is the damaged head, never a grant to make.
      assert Accounts.resolve(ctx, :default, bad, "Work") ==
               {:error, {:head_corrupt, bad_profile}}
    end
  end
end
