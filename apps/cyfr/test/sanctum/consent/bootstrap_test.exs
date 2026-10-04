# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.BootstrapTest do
  use ExUnit.Case, async: false

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
