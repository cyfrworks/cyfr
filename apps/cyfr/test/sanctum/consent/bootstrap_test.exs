# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.BootstrapTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Sanctum.Consent.Bootstrap
  alias Sanctum.Consent.Loader

  @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "consent_bootstrap_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)
    Cyfr.Test.SeedBundle.isolate!()

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local(:prism)}
  end

  defp ship!(ctx, name, type) do
    {:ok, component} =
      Arca.Test.UnitFixtures.ship_and_register!(ctx, type, "local", name, "1.0.0",
        manifest: %{
          "name" => name,
          "type" => type,
          "version" => "1.0.0",
          "publisher" => "local",
          "description" => "bootstrap test"
        },
        wasm: @wasm
      )

    component
  end

  test "mints a loadable consent whose blob mirrors effective policy", %{ctx: ctx} do
    ship!(ctx, "boot-plain", "reagent")

    assert {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert "reagent:local.boot-plain" in minted

    # The minted rows load through the real DB source into an Authority.
    {:ok, [profile]} =
      Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), "reagent:local.boot-plain")

    assert profile.kind == :owner
    assert profile.status == :active

    {:ok, consent} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile.id)
    assert consent.revision == 1
    assert consent.scope == :versionless

    # The blob round-trips the frozen grammar.
    assert {:ok, %Blob{}} = Blob.parse(consent.resolved_policy)

    {:ok, component} = Compendium.Registry.get_latest(ctx, "boot-plain", "local", "reagent")
    {:ok, live} = Compendium.Activation.resolve_verified(ctx, component)

    assert {:ok, %Authority{} = auth, _stamp} =
             Loader.load_root(ctx, profile, live: {:ok, live})

    assert auth.cursor == {:bound, "reagent:local.boot-plain"}
  end

  test "a second run skips what the first minted", %{ctx: ctx} do
    ship!(ctx, "boot-idem", "reagent")

    assert {:ok, %{minted: first}} = Bootstrap.run(ctx)
    assert "reagent:local.boot-idem" in first

    assert {:ok, %{minted: second, skipped: skipped}} = Bootstrap.run(ctx)
    refute "reagent:local.boot-idem" in second
    assert {"reagent:local.boot-idem", :already_bootstrapped} in skipped
  end

  test "every local component is considered, past the default listing page", %{ctx: ctx} do
    # Use 101 rows to verify bootstrap traverses beyond one listing page,
    # including components reported as skipped.
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for i <- 1..101 do
      {:ok, _} =
        Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
          id: Ecto.UUID.generate(),
          name: "bulk-#{i}",
          version: "1.0.0",
          component_type: "reagent",
          description: "bulk",
          tags: "[]",
          category: "test",
          license: "MIT",
          digest: "sha256:#{:crypto.hash(:sha256, "bulk-#{i}") |> Base.encode16(case: :lower)}",
          size: 1,
          exports: "[]",
          manifest: "{}",
          publisher: "local",
          publisher_id: nil,
          source: Compendium.Source.filesystem(),
          signature_verified: false,
          signer_identity: nil,
          signer_issuer: nil,
          inserted_at: now,
          updated_at: now
        })
    end

    assert {:ok, %{minted: minted, skipped: skipped}} = Bootstrap.run(ctx)
    assert length(minted) + length(skipped) == 101
  end

  describe "the instance's entry at first sign-in" do
    @model "catalyst:local.boot-model"
    @inference ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"})

    # A shipped catalyst whose one need attaches a key of `provider`, an
    # openai.com one unless a release says otherwise.
    defp ship_model!(ctx, version \\ "1.0.0", caps \\ %{}, provider \\ "openai.com") do
      {:ok, component} =
        Arca.Test.UnitFixtures.ship_and_register!(ctx, "catalyst", "local", "boot-model", version,
          manifest: %{
            "name" => "boot-model",
            "type" => "catalyst",
            "version" => version,
            "publisher" => "local",
            "needs" => %{
              "api_key" => %{
                "type" => "api_key:#{provider}",
                "reason" => "to call the model",
                "fields" => ["OPENAI_API_KEY"],
                "attach" => %{
                  "in" => "header",
                  "name" => "Authorization",
                  "template" => "Bearer {value}"
                }
              }
            },
            "caps" => caps
          },
          wasm: @wasm
        )

      component
    end

    defp offer!(over \\ %{}) do
      {:ok, entry} =
        Arca.InstanceEntries.put(
          Arca.Test.Actor.platform(),
          Map.merge(
            %{
              name: "company-#{System.unique_integer([:positive])}",
              kind: "api_key",
              provider_hint: "openai.com",
              field_names: ~s(["OPENAI_API_KEY"]),
              destination: @inference,
              sealed_payload: "sealed",
              binding_digest: "sha256:company-#{System.unique_integer([:positive])}",
              audience: "everyone",
              created_by: "usr_admin",
              component_policy: "shipped"
            },
            over
          )
        )

      entry
    end

    defp model_head!(ctx) do
      {:ok, [profile]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), @model)
      {:ok, head} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile.id)
      {:ok, blob} = Blob.parse(head.resolved_policy)
      {:ok, ingress} = Blob.ingress(blob, @model)
      {head, ingress.vault}
    end

    # The server's own context a boot's seed sync runs under: no person.
    defp seed(ctx),
      do: Sanctum.internal_context(user_id: "_seed", athanor_id: ctx.athanor_id, scope: :athanor)

    # What a first mint that could not read the instance entries skips.
    @unavailable {:unavailable, "Instance entries"}

    # Run `fun` once, right after the walk's first read of `table`: for
    # the instance entries at a first mint, the entries offered to its
    # person, before the chosen entry's binding is read; for the binding
    # rows, the head's, before a revision reads the entry it keeps.
    defp after_read!(table, fun) do
      test = self()
      handler = "bootstrap-after-read-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measurements, meta, _config ->
            if self() == test and meta[:source] == table do
              :telemetry.detach(handler)
              Task.async(fun) |> Task.await(30_000)
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    defp entries_away!,
      do: Arca.Repo.query!("ALTER TABLE instance_entries RENAME TO instance_entries_unavailable")

    defp entries_back!,
      do: Arca.Repo.query!("ALTER TABLE instance_entries_unavailable RENAME TO instance_entries")

    defp no_profile?(ctx),
      do: Arca.ProfileStorage.list_for_source(Sanctum.Context.actor(ctx), @model) == {:ok, []}

    # A head's binding rows gone from under the blob that names them.
    defp drop_refs!(consent_id) do
      import Ecto.Query, only: [from: 2]

      {1, _} =
        Arca.Repo.delete_all(
          from(r in Arca.Schemas.ConsentVaultRef, where: r.consent_id == ^consent_id)
        )

      :ok
    end

    defp set_manifest!(component, manifest) do
      import Ecto.Query, only: [from: 2]

      manifest = if is_map(manifest), do: Jason.encode!(manifest), else: manifest

      {1, _} =
        Arca.Repo.update_all(
          from(c in Arca.Schemas.Component,
            where: c.athanor_id == ^component.athanor_id and c.id == ^component.id
          ),
          set: [manifest: manifest]
        )

      Arca.Cache.delete_match(:_)
    end

    # The catalyst's head and its binding rows, as stored.
    defp head_rows!(ctx) do
      {:ok, head, refs} =
        Arca.ConsentStorage.get_head(Sanctum.Context.actor(ctx), head_profile_id(ctx))

      {head, refs}
    end

    # The catalyst's head at `revision`, minted or revised by the
    # bootstrap, binds `entry` in the ingress's default slot, standing:
    # its one binding row, whole.
    defp assert_bound!(ctx, entry, revision \\ 1) do
      {head, refs} = head_rows!(ctx)
      granted_by = if ctx.auth_method == :system, do: "system:bootstrap", else: ctx.user_id

      assert {head.revision, head.granted_via, head.granted_by} ==
               {revision, "bootstrap", granted_by}

      assert refs == [
               %{
                 consent_id: head.id,
                 athanor_id: ctx.athanor_id,
                 binding_key: "#{@model}|@ingress|default",
                 scope: "instance",
                 vault_entry_id: nil,
                 instance_entry_id: entry.id,
                 via_label: nil,
                 binding_digest: entry.binding_digest,
                 lifetime_kind: "standing",
                 expires_at: nil,
                 consumed_by_root: nil
               }
             ]
    end

    # A revoke of `entry_id` landing right after the boot's revision read
    # the entry's facts and before its transaction locks the entry: run
    # from the walk's first read of an instance entry, once.
    def revoke_after_facts(_event, _measurements, meta, %{test: test, entry_id: entry_id}) do
      if self() == test and meta[:source] == "instance_entries" and
           Process.get(:a0_revoked) == nil do
        revoked =
          Task.async(fn ->
            Arca.InstanceEntries.revoke(Arca.Test.Actor.platform(), entry_id, "needs_consent")
          end)
          |> Task.await(30_000)

        Process.put(:a0_revoked, revoked)
      end
    end

    setup %{ctx: ctx} do
      {person, _user} = Sanctum.TestContext.person!(ctx)
      {:ok, person: person}
    end

    test "a newly provisioned athanor binds its sole offered provider entry", %{person: person} do
      ship_model!(person)
      offered = offer!()
      _other_provider = offer!(%{provider_hint: "anthropic.com"})

      assert {:ok, %{minted: minted}} = Bootstrap.run(person)
      assert @model in minted

      {head, vault} = model_head!(person)

      # The default slot, scoped instance, standing; a recorded bootstrap
      # revision like every machine mint.
      assert %{entry_id: id, scope: "instance", binding_key: key} = vault
      assert id == offered.id
      assert key == "#{@model}|@ingress|default"
      assert vault.attach.name == "Authorization"
      refute Map.has_key?(vault, :named)

      assert [%{instance_entry_id: ^id, scope: "instance", lifetime_kind: "standing"}] =
               head.vault_refs

      {:ok, row, _refs} =
        Arca.ConsentStorage.get_head(Sanctum.Context.actor(person), head_profile_id(person))

      assert row.granted_via == "bootstrap"
    end

    test "two offered entries of the provider bind none; the next grant suggests", %{
      person: person
    } do
      ship_model!(person)
      offer!()
      offer!()

      assert {:ok, %{minted: minted}} = Bootstrap.run(person)
      assert @model in minted

      {head, vault} = model_head!(person)
      assert vault == nil
      assert head.vault_refs == []

      # At the next grant the person chooses between them.
      {:ok, plan} = Sanctum.Consent.Plan.plan(person, %{ref: @model})
      row = Enum.find(plan.needs, &(&1.need == "api_key"))
      assert length(row.candidates) == 2
      assert row.suggested == nil and row.choice_required
    end

    test "a server-side mint has no person and binds nothing", %{ctx: ctx} do
      ship_model!(ctx)
      offer!()

      seed_ctx =
        Sanctum.internal_context(user_id: "_seed", athanor_id: ctx.athanor_id, scope: :athanor)

      assert {:ok, %{minted: minted}} = Bootstrap.run(seed_ctx)
      assert @model in minted
      assert {_head, nil} = model_head!(ctx)
    end

    # The first mint is the only one that binds the instance entry, so a
    # read of the entries offered that could not answer is never nothing
    # offered: minted without the entry, the catalyst's person would have
    # to connect a key over an entry that exists.
    @tag :capture_log
    test "an outage reading the entries offered mints nothing for the catalyst, and a run " <>
           "once the store answers mints it bound",
         %{person: person} do
      ship_model!(person)
      offered = offer!()

      entries_away!()
      {unanswered, log} = with_log(fn -> Bootstrap.run(person) end)
      entries_back!()

      assert unanswered == {:ok, %{minted: [], revised: [], skipped: [{@model, @unavailable}]}}
      assert log =~ "#{@model} skipped: Instance entries could not answer (:database_error)"
      assert no_profile?(person)

      assert Bootstrap.run(person) == {:ok, %{minted: [@model], revised: [], skipped: []}}
      assert_bound!(person, offered)
    end

    # The chosen entry's binding is the same read: an outage there skips
    # the same way.
    @tag :capture_log
    test "an outage reading the chosen entry's binding mints nothing for the catalyst, and a " <>
           "run once the store answers mints it bound",
         %{person: person} do
      ship_model!(person)
      offered = offer!()

      after_read!("instance_entries", &entries_away!/0)
      {unanswered, log} = with_log(fn -> Bootstrap.run(person) end)
      entries_back!()

      assert unanswered == {:ok, %{minted: [], revised: [], skipped: [{@model, @unavailable}]}}
      assert log =~ "#{@model} skipped: Instance entries could not answer (:database_error)"
      assert no_profile?(person)

      assert Bootstrap.run(person) == {:ok, %{minted: [@model], revised: [], skipped: []}}
      assert_bound!(person, offered)
    end

    # The binding read's other refusals say nothing usable is offered:
    # the catalyst is minted without the entry, as before.
    @tag :capture_log
    test "a chosen entry its binding read answers not offered mints the catalyst without it",
         %{person: person} do
      ship_model!(person)
      offered = offer!()

      after_read!("instance_entries", fn ->
        {:ok, _blocked} =
          Arca.InstanceEntries.tombstone(Arca.Test.Actor.platform(), offered.id, "needs_consent")
      end)

      {answer, log} = with_log(fn -> Bootstrap.run(person) end)

      assert answer == {:ok, %{minted: [@model], revised: [], skipped: []}}
      assert log =~ "no instance entry bound for #{@model}: :not_offered"
      assert {head, nil} = model_head!(person)
      assert head.vault_refs == []
    end

    @tag :capture_log
    test "a chosen entry its binding read answers not active mints the catalyst without it",
         %{person: person} do
      ship_model!(person)
      offered = offer!()

      after_read!("instance_entries", fn ->
        {:ok, _blocked} =
          Arca.InstanceEntries.revoke(Arca.Test.Actor.platform(), offered.id, "needs_consent")
      end)

      {answer, log} = with_log(fn -> Bootstrap.run(person) end)

      assert answer == {:ok, %{minted: [@model], revised: [], skipped: []}}
      assert log =~ ~s(no instance entry bound for #{@model}: {:entry_unavailable, "revoked"})
      assert {head, nil} = model_head!(person)
      assert head.vault_refs == []
    end

    test "with no instance entry offered the catalyst is minted without one, and nothing is " <>
           "skipped",
         %{person: person} do
      ship_model!(person)

      assert Bootstrap.run(person) == {:ok, %{minted: [@model], revised: [], skipped: []}}
      assert {head, nil} = model_head!(person)
      assert head.vault_refs == []
    end

    # A context that is not the server's but names no person has nothing
    # offered to it, as `Sanctum.Consent.Plan` reads the same refusal: the
    # read answered, and the catalyst is minted without an entry.
    test "a context with no person is offered nothing, and the catalyst is minted without a " <>
           "binding",
         %{person: person} do
      ship_model!(person)
      offer!()
      no_person = %{person | user_id: nil}

      assert {:error, :not_offered} = Sanctum.InstanceEntries.offered(no_person)
      assert Bootstrap.run(no_person) == {:ok, %{minted: [@model], revised: [], skipped: []}}
      assert {head, nil} = model_head!(person)
      assert head.vault_refs == []
    end

    test "an anonymous context is offered nothing, and the catalyst is minted without a binding",
         %{person: person} do
      ship_model!(person)
      offer!()
      anonymous = %{person | anonymous: true}

      assert {:error, :anonymous_denied} = Sanctum.InstanceEntries.offered(anonymous)
      assert Bootstrap.run(anonymous) == {:ok, %{minted: [@model], revised: [], skipped: []}}
      assert {head, nil} = model_head!(person)
      assert head.vault_refs == []
    end

    # A server-side mint has no person to read the offer as, so it reads
    # none, and an outage of the store holds nothing up.
    test "a server-side mint under an instance-entries outage reads no offer and mints " <>
           "without a binding",
         %{ctx: ctx} do
      ship_model!(ctx)
      offer!()

      entries_away!()
      answer = Bootstrap.run(seed(ctx))
      entries_back!()

      assert answer == {:ok, %{minted: [@model], revised: [], skipped: []}}
      assert {head, nil} = model_head!(ctx)
      assert head.vault_refs == []
    end

    # A revision under a person keeps the head's entry only once it read
    # it: a binding read the store could not answer keeps the head as it
    # stands, never revised without the entry it bound.
    @tag :capture_log
    test "a revision under a person that cannot read the entry its head binds keeps the head, " <>
           "and a run once the store answers revises it bound",
         %{person: person} do
      ship_model!(person)
      offered = offer!()
      {:ok, _} = Bootstrap.run(person)
      held = head_rows!(person)

      # The release moves the shape; the store goes once the head is read.
      ship_model!(person, "1.1.0", %{"limits" => %{"timeout" => "2m"}})
      after_read!("consent_vault_refs", &entries_away!/0)
      {unanswered, log} = with_log(fn -> Bootstrap.run(person) end)
      entries_back!()

      assert unanswered == {:ok, %{minted: [], revised: [], skipped: [{@model, @unavailable}]}}
      assert log =~ "#{@model} skipped: Instance entries could not answer (:database_error)"
      assert head_rows!(person) == held

      assert Bootstrap.run(person) == {:ok, %{minted: [], revised: [@model], skipped: []}}
      assert_bound!(person, offered, 2)
    end

    # A boot's revision carries the head's instance binding as the head
    # holds it, so a head it cannot read whole is damaged, not a head that
    # bound nothing: the source is skipped with the head kept.
    test "a boot's revision of a head whose policy does not parse is the profile damaged, " <>
           "and the head is kept",
         %{ctx: ctx, person: person} do
      ship_model!(person)
      offer!()
      {:ok, _} = Bootstrap.run(person)
      profile_id = head_profile_id(person)
      :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(person, profile_id, resolved_policy: "{")
      damaged = head_rows!(person)

      ship_model!(person, "1.1.0", %{"limits" => %{"timeout" => "2m"}})

      assert Bootstrap.run(seed(ctx)) ==
               {:ok,
                %{
                  minted: [],
                  revised: [],
                  skipped: [{@model, {:corrupt, {:profile, profile_id}}}]
                }}

      assert head_rows!(person) == damaged
    end

    # Valid JSON can still hold a node or edge map the authority grammar
    # refuses. The head is validated before any traversal of that shape.
    for damaged <- [:node, :edges] do
      @tag structural_head_damage: true
      @tag damaged_shape: damaged
      test "a boot's revision of a head with malformed #{damaged} structure skips the " <>
             "damaged profile and keeps the whole head",
           %{ctx: ctx, person: person, damaged_shape: damaged} do
        ship_model!(person)
        offer!()
        {:ok, _} = Bootstrap.run(person)
        profile_id = head_profile_id(person)
        {head, [_bound]} = head_rows!(person)
        decoded = Jason.decode!(head.resolved_policy)

        corrupted =
          case damaged do
            :node -> put_in(decoded, ["nodes", @model], 42)
            :edges -> put_in(decoded, ["nodes", @model, "edges"], 42)
          end
          |> Jason.encode!()

        assert {:ok, _} = Jason.decode(corrupted)
        assert {:error, _} = Blob.parse(corrupted)

        :ok =
          Sanctum.Test.ConsentFixtures.hand_edit_head!(person, profile_id,
            resolved_policy: corrupted
          )

        held = head_rows!(person)
        ship_model!(person, "1.1.0", %{"limits" => %{"timeout" => "2m"}})

        assert Bootstrap.run(seed(ctx)) ==
                 {:ok,
                  %{
                    minted: [],
                    revised: [],
                    skipped: [{@model, {:corrupt, {:profile, profile_id}}}]
                  }}

        assert head_rows!(person) == held
      end
    end

    test "a boot's revision of a head whose ingress binding has no ref row is the profile " <>
           "damaged, and the head is kept",
         %{ctx: ctx, person: person} do
      ship_model!(person)
      offer!()
      {:ok, _} = Bootstrap.run(person)
      profile_id = head_profile_id(person)
      {head, [_bound]} = head_rows!(person)
      drop_refs!(head.id)
      assert head_rows!(person) == {head, []}

      ship_model!(person, "1.1.0", %{"limits" => %{"timeout" => "2m"}})

      assert Bootstrap.run(seed(ctx)) ==
               {:ok,
                %{
                  minted: [],
                  revised: [],
                  skipped: [{@model, {:corrupt, {:profile, profile_id}}}]
                }}

      assert head_rows!(person) == {head, []}
    end

    # The shape derivation refuses a source whose stored manifest does not
    # decode, by the same term: whichever read meets it first, the person
    # is told the manifest is damaged, and nothing is minted without the
    # entry it is offered.
    @tag :capture_log
    test "a catalyst whose stored manifest does not decode is skipped as damaged, and nothing " <>
           "is minted",
         %{person: person} do
      component = ship_model!(person)
      offer!()
      set_manifest!(component, "{not json")

      assert Bootstrap.run(person) ==
               {:ok,
                %{minted: [], revised: [], skipped: [{@model, {:corrupt, {:manifest, @model}}}]}}

      assert no_profile?(person)

      assert Prima.Refusal.message({:corrupt, {:manifest, @model}}) ==
               "The stored manifest is damaged."
    end

    # The walk keeps the row it read. Repairing storage before its later
    # reads must not turn that unreadable snapshot into an unbound mint.
    @tag :capture_log
    test "a mint that read a damaged manifest skips even when storage is repaired before its " <>
           "later reads, and the next run mints it bound",
         %{person: person} do
      component = ship_model!(person)
      offered = offer!()
      set_manifest!(component, "{not json")
      after_read!("components", fn -> set_manifest!(component, component.manifest) end)

      assert Bootstrap.run(person) ==
               {:ok,
                %{minted: [], revised: [], skipped: [{@model, {:corrupt, {:manifest, @model}}}]}}

      assert no_profile?(person)
      assert Bootstrap.run(person) == {:ok, %{minted: [@model], revised: [], skipped: []}}
      assert_bound!(person, offered)
    end

    for mode <- [:person, :seed] do
      @tag :capture_log
      @tag revision_context: mode
      test "a #{mode} revision that read a damaged manifest keeps the whole head even when " <>
             "storage is repaired before its later reads",
           %{ctx: ctx, person: person, revision_context: mode} do
        ship_model!(person)
        offered = offer!()
        {:ok, _} = Bootstrap.run(person)
        held = head_rows!(person)

        component = ship_model!(person, "1.1.0", %{"limits" => %{"timeout" => "2m"}})
        set_manifest!(component, "{not json")
        after_read!("components", fn -> set_manifest!(component, component.manifest) end)
        revision_ctx = if mode == :person, do: person, else: seed(ctx)

        assert Bootstrap.run(revision_ctx) ==
                 {:ok,
                  %{
                    minted: [],
                    revised: [],
                    skipped: [{@model, {:corrupt, {:manifest, @model}}}]
                  }}

        assert head_rows!(person) == held

        assert Bootstrap.run(revision_ctx) ==
                 {:ok, %{minted: [], revised: [@model], skipped: []}}

        assert_bound!(revision_ctx, offered, 2)
      end
    end

    test "a claim taken over after the offered entries are read mints no profile", %{
      person: person
    } do
      ship_model!(person)
      offer!()
      actor = Sanctum.Context.actor(person)
      test = self()

      {:ok, stale} =
        Arca.ProvisioningClaims.claim(actor, "boot_elsewhere/own_walk", "sign_in", 1, :none)

      after_read!("instance_entries", fn ->
        Prima.Test.Wait.wait_until(
          fn -> not Arca.ProvisioningClaims.live?(stale) end,
          2_000,
          "the claim to expire before its takeover"
        )

        {:ok, successor} =
          Arca.ProvisioningClaims.claim(
            actor,
            "boot_elsewhere/own_successor",
            "sign_in",
            60_000,
            :none
          )

        send(test, {:claim_taken, successor})
      end)

      assert Bootstrap.run(person, stale) == {:error, :claim_lost}
      assert_receive {:claim_taken, successor}
      assert successor.fence == stale.fence + 1
      assert no_profile?(person)
      assert Arca.ProvisioningClaims.current(actor) == {:ok, successor}
    end

    test "an athanor provisioned before an entry is offered is not revised under its people",
         %{person: person} do
      ship_model!(person)
      {:ok, _} = Bootstrap.run(person)
      {before, nil} = model_head!(person)

      offered = offer!()

      assert {:ok, %{minted: [], revised: [], skipped: skipped}} = Bootstrap.run(person)
      assert {@model, :already_bootstrapped} in skipped
      {head, vault} = model_head!(person)
      assert head.id == before.id and vault == nil

      # The entry is the suggestion the next time the need is granted.
      {:ok, plan} = Sanctum.Consent.Plan.plan(person, %{ref: @model})
      row = Enum.find(plan.needs, &(&1.need == "api_key"))
      assert row.suggested == %{instance_entry_id: offered.id}
      assert row.source == "instance"
    end

    test "a revision keeps the head's binding while it is offered at its digest, and binds " <>
           "none once it was rebound",
         %{person: person} do
      ship_model!(person)
      offered = offer!()
      {:ok, _} = Bootstrap.run(person)

      # The release moves the shape: the bootstrap-only head is revised,
      # and the entry it bound, unchanged and still offered, stays bound.
      ship_model!(person, "1.1.0", %{"limits" => %{"timeout" => "2m"}})
      assert {:ok, %{revised: [@model]}} = Bootstrap.run(person)
      {head, vault} = model_head!(person)
      assert head.revision == 2
      assert vault.entry_id == offered.id

      # Rebound since: the next revision binds none, and adds none back.
      {:ok, _} =
        Arca.InstanceEntries.move_binding(
          Arca.Test.Actor.platform(),
          offered.id,
          offered.binding_digest,
          %{
            destination:
              ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v2/"],"scheme":"https"}),
            binding_digest: "sha256:moved"
          },
          "needs_consent"
        )

      ship_model!(person, "1.2.0", %{"limits" => %{"timeout" => "3m"}})
      # The rebind blocked the profile; a bootstrap revision is still the
      # seed's to write over a bootstrap-only head.
      assert {:ok, %{revised: [@model]}} = Bootstrap.run(person)
      {head, vault} = model_head!(person)
      assert head.revision == 3
      assert vault == nil
    end

    test "a boot's revision with no person carries the head's binding as held, is refused " <>
           "by a revoke landing after its read, and then binds none",
         %{ctx: ctx, person: person} do
      ship_model!(person)
      offered = offer!()
      {:ok, _} = Bootstrap.run(person)
      {first, bound} = model_head!(person)
      assert bound.entry_id == offered.id
      [first_row] = first.vault_refs

      # A boot's seed sync runs under the server's own context: no person
      # to read the offer as. The release moves the shape, and the revision
      # carries the entry, its digest, its key and its lifetime unchanged.
      seed_ctx = seed(ctx)

      ship_model!(person, "1.1.0", %{"limits" => %{"timeout" => "2m"}})
      assert {:ok, %{revised: [@model]}} = Bootstrap.run(seed_ctx)
      {head, vault} = model_head!(person)
      assert head.revision == 2

      assert %{entry_id: id, binding_digest: digest, binding_key: key, scope: "instance"} = vault
      assert {id, digest, key} == {offered.id, offered.binding_digest, bound.binding_key}
      assert vault.destination == bound.destination
      assert vault.attach.name == "Authorization"

      assert [row] = head.vault_refs

      assert Map.take(row, [:binding_key, :instance_entry_id, :binding_digest, :scope]) ==
               Map.take(first_row, [:binding_key, :instance_entry_id, :binding_digest, :scope])

      assert {row.lifetime_kind, row.expires_at} ==
               {first_row.lifetime_kind, first_row.expires_at}

      {:ok, stored, _refs} =
        Arca.ConsentStorage.get_head(Sanctum.Context.actor(person), head_profile_id(person))

      assert stored.granted_by == "system:bootstrap"

      # A revoke landing after the revision read the entry as active: the
      # revision's lock refuses the entry, nothing is written, and the boot
      # reports the source skipped with the refusal.
      ship_model!(person, "1.2.0", %{"limits" => %{"timeout" => "3m"}})
      handler = {__MODULE__, :revoke_after_facts, System.unique_integer([:positive])}

      :ok =
        :telemetry.attach(handler, [:arca, :repo, :query], &__MODULE__.revoke_after_facts/4, %{
          test: self(),
          entry_id: offered.id
        })

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, %{revised: [], skipped: skipped}} = Bootstrap.run(seed_ctx)
      :telemetry.detach(handler)
      assert {:ok, [_blocked]} = Process.get(:a0_revoked)
      assert {@model, {:entry_unavailable, "revoked"}} in skipped
      {after_revoke, _vault} = model_head!(person)
      assert after_revoke.id == head.id

      # Read as revoked, the entry is carried no further: the next boot's
      # revision binds none.
      assert {:ok, %{revised: [@model]}} = Bootstrap.run(seed_ctx)
      {unbound, vault} = model_head!(person)
      assert unbound.revision == 3
      assert vault == nil and unbound.vault_refs == []
    end

    test "a boot's revision carries nothing to a release whose need names another provider",
         %{ctx: ctx, person: person} do
      ship_model!(person)
      offered = offer!()
      {:ok, _} = Bootstrap.run(person)
      {_first, bound} = model_head!(person)
      assert bound.entry_id == offered.id

      # The same need, now of anthropic.com: the openai.com entry meets it no
      # longer, and the revision binds none.
      ship_model!(person, "1.1.0", %{}, "anthropic.com")
      assert {:ok, %{revised: [@model]}} = Bootstrap.run(seed(ctx))
      {head, vault} = model_head!(person)
      assert head.revision == 2
      assert vault == nil and head.vault_refs == []
    end

    test "a boot's revision carries nothing once the entry was rebound past the head's digest",
         %{ctx: ctx, person: person} do
      ship_model!(person)
      offered = offer!()
      {:ok, _} = Bootstrap.run(person)
      {_first, bound} = model_head!(person)
      assert bound.binding_digest == offered.binding_digest

      {:ok, _} =
        Arca.InstanceEntries.move_binding(
          Arca.Test.Actor.platform(),
          offered.id,
          offered.binding_digest,
          %{
            destination:
              ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v2/"],"scheme":"https"}),
            binding_digest: "sha256:moved"
          },
          "needs_consent"
        )

      # Still active and still of the need's provider, but no longer at the
      # digest the head bound: the revision binds none.
      ship_model!(person, "1.1.0", %{"limits" => %{"timeout" => "2m"}})
      assert {:ok, %{revised: [@model]}} = Bootstrap.run(seed(ctx))
      {head, vault} = model_head!(person)
      assert head.revision == 2
      assert vault == nil and head.vault_refs == []
    end

    # A shipped catalyst whose one need attaches a token of an OAuth entry
    # authorized for `scopes`.
    defp ship_oauth_model!(ctx, version, scopes) do
      {:ok, component} =
        Arca.Test.UnitFixtures.ship_and_register!(ctx, "catalyst", "local", "boot-model", version,
          manifest: %{
            "name" => "boot-model",
            "type" => "catalyst",
            "version" => version,
            "publisher" => "local",
            "needs" => %{
              "calendar" => %{
                "type" => "oauth:openai.com",
                "reason" => "to read the calendar",
                "scopes" => scopes,
                "attach" => %{"in" => "header", "name" => "Authorization"}
              }
            }
          },
          wasm: @wasm
        )

      component
    end

    test "a boot's revision carries nothing to a release whose OAuth need asks for scopes " <>
           "the entry does not hold",
         %{ctx: ctx, person: person} do
      ship_oauth_model!(person, "1.0.0", ["calendar.read"])
      offered = offer!(%{kind: "oauth", oauth_scopes: ~s(["calendar.read"])})
      {:ok, _} = Bootstrap.run(person)
      {_first, bound} = model_head!(person)
      assert bound.entry_id == offered.id

      # The same need, now asking for a scope the entry was never authorized
      # for: a first binding would not take the entry, so the revision with
      # no person carries it no further.
      ship_oauth_model!(person, "1.1.0", ["calendar.read", "calendar.write"])
      assert {:ok, %{revised: [@model]}} = Bootstrap.run(seed(ctx))
      {head, vault} = model_head!(person)
      assert head.revision == 2
      assert vault == nil and head.vault_refs == []
    end

    defp head_profile_id(ctx) do
      {:ok, [profile]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), @model)
      profile.id
    end
  end

  test "consents are insert-only by export list" do
    exports = Arca.ConsentStorage.__info__(:functions) |> Keyword.keys()

    refute Enum.any?(exports, fn name ->
             name |> Atom.to_string() |> String.starts_with?("update")
           end)
  end

  test "the head pointer only advances by compare-and-swap", %{ctx: ctx} do
    ship!(ctx, "boot-cas", "reagent")
    {:ok, _} = Bootstrap.run(ctx)

    {:ok, [profile]} =
      Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), "reagent:local.boot-cas")

    {:ok, consent} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile.id)

    # A stale expectation cannot advance the head.
    assert {:error, :head_moved} =
             Arca.ProfileStorage.advance_head(
               Sanctum.Context.actor(ctx),
               profile.id,
               "cons_stale",
               "cons_new"
             )

    # The true expectation can.
    assert :ok =
             Arca.ProfileStorage.advance_head(
               Sanctum.Context.actor(ctx),
               profile.id,
               consent.id,
               consent.id
             )
  end
end
