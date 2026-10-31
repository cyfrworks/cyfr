# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.BootstrapTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Cyfr.Test.ShareFixtures
  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Sanctum.Consent.BlobBuilder
  alias Sanctum.Consent.Bootstrap
  alias Sanctum.Consent.Loader

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
        wasm: Cyfr.Test.Guests.wasm(type)
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
      digest = "sha256:#{:crypto.hash(:sha256, "bulk-#{i}") |> Base.encode16(case: :lower)}"
      {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, %{})

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
          digest: digest,
          release_digest: release_digest,
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

  describe "the administrator's key at first sign-in" do
    @model "catalyst:local.boot-model"
    @inference ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"})
    @anthropic_inference ~s({"hosts":["api.anthropic.com"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"})

    # What a mint or a revision that could not read a store skips.
    @shares_unavailable {:unavailable, "Shares"}
    @instance_unavailable {:unavailable, "Instance entries"}

    # A shipped catalyst whose one need attaches an openai.com key calling
    # `hosts`, api.openai.com unless a release says otherwise, which its
    # caps reach.
    defp ship_model!(ctx, version \\ "1.0.0", caps \\ %{}, hosts \\ ["api.openai.com"]) do
      {:ok, component} =
        Arca.Test.UnitFixtures.ship_and_register!(ctx, "catalyst", "local", "boot-model", version,
          manifest: %{
            "name" => "boot-model",
            "type" => "catalyst",
            "version" => version,
            "publisher" => "local",
            "needs" => %{
              "api_key" => %{
                "type" => "api_key:openai.com",
                "reason" => "to call the model",
                "fields" => ["OPENAI_API_KEY"],
                "hosts" => hosts,
                "attach" => %{
                  "in" => "header",
                  "name" => "Authorization",
                  "template" => "Bearer {value}"
                }
              }
            },
            "caps" => Map.put(caps, "egress", %{"domains" => hosts})
          },
          wasm: Cyfr.Test.Guests.wasm(:catalyst)
        )

      component
    end

    # The platform administrator: a person of their own athanor holding
    # the platform membership.
    defp administrator! do
      admin = ShareFixtures.person!("Admin")
      {:ok, _seat} = Sanctum.TestContext.ensure_platform(admin.user.id)
      admin
    end

    # `owner` shares with everyone an attach-only openai.com key of their
    # own athanor, its one field `OPENAI_API_KEY`, to the inference API,
    # or the key `over` names, stored at the digest its binding columns
    # derive: `%{entry: _, share: _}`.
    defp share!(owner, over \\ %{}) do
      attrs =
        Map.merge(
          %{
            kind: "api_key",
            provider_hint: "openai.com",
            field_names: ~s(["OPENAI_API_KEY"]),
            destination: @inference,
            attach_only: true
          },
          over
        )

      {:ok, digest} =
        Sanctum.VaultReader.binding_digest(
          Map.merge(attrs, %{oauth_endpoints: nil, oauth_scopes: nil})
        )

      entry = Arca.Test.Shares.entry!(owner.actor, Map.put(attrs, :binding_digest, digest))
      %{entry: entry, share: Arca.Test.Shares.share!(owner.actor, entry.id)}
    end

    # An instance entry offered to everyone, admitting only shipped code.
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

    # A bootstrap-only head of the catalyst `ref` whose ingress binds the
    # instance entry `entry` in the default slot, standing, at revision 1,
    # granted by the context's person: a head minted when a first sign-in
    # still bound an instance entry, built by the bootstrap's own builders
    # as that mint built it. A boot revises such a head while the instance
    # entries stand.
    defp instance_head!(ctx, entry, ref \\ @model) do
      {:ok, cref} = Prima.ComponentRef.parse(ref)

      {:ok, component} =
        Sanctum.Consent.Components.get_latest(ctx, cref.name, cref.namespace, cref.type)

      {:ok, activation} = Sanctum.Consent.Components.resolve(ctx, component)
      {:ok, manifest} = Prima.Manifest.decode_strict(component.manifest)
      [need] = Prima.Manifest.Needs.from_manifest(manifest)
      {:ok, destination} = Prima.Destination.from_map(Jason.decode!(entry.destination))
      fields = Sanctum.Consent.Plan.field_map(need, Jason.decode!(entry.field_names))

      binding = %{
        need: need.name,
        entry_id: entry.id,
        binding_digest: entry.binding_digest,
        scope: "instance",
        destination: Prima.Destination.to_map(destination),
        attach: Prima.Manifest.Needs.attach_to_map(need.attach),
        fields: fields,
        scopes: need.scopes,
        lifetime: %{kind: "standing", until: nil},
        renew: false
      }

      vault_fn = fn node_key, _row, _manifest ->
        if node_key == ref, do: BlobBuilder.vault_resource(binding)
      end

      {:ok, nodes} =
        BlobBuilder.build(ctx, activation.graph, ref, vault_fn, source_row: component)

      {:ok, blob} = BlobBuilder.encode(nodes)
      blob_digest = Prima.Digest.sha256(blob)
      {:ok, input} = Sanctum.Consent.ShapeDerivation.shape_input(ctx, ref)
      {:ok, shape_digest} = Sanctum.Consent.ShapeDigest.compute(input)

      {:ok, commit_digest} =
        Sanctum.Consent.CommitDigest.compute(%{
          shape_digest: shape_digest,
          blob_digest: blob_digest,
          label: "default",
          kind: :owner,
          invoke_mode: :open_inert,
          origins: [:interactive, :programmatic],
          bindings: [
            %{
              need: need.name,
              instance_entry_id: entry.id,
              binding_digest: entry.binding_digest,
              fields: fields,
              scopes: need.scopes,
              lifetime: %{kind: "standing"},
              renew: false
            }
          ]
        })

      {:ok, activation_json} = Prima.JCS.encode(activation.graph)
      profile_id = Prima.UUID7.generate_id("prof")

      {:ok, _consent} =
        Arca.ConsentStorage.mint_profile_with_revision(
          %{
            id: profile_id,
            athanor_id: ctx.athanor_id,
            source_ref: ref,
            kind: "owner",
            label: "default",
            status: "active"
          },
          %{
            profile_id: profile_id,
            revision: 1,
            scope: "versionless",
            pinned_version: "",
            invoke_mode: "open_inert",
            shape_digest: shape_digest,
            commit_digest: commit_digest,
            blob_digest: blob_digest,
            resolved_policy: blob,
            activation: activation_json,
            admitted_origins: [:interactive, :programmatic],
            granted_by: ctx.user_id,
            granted_via: "bootstrap"
          },
          BlobBuilder.vault_refs(nodes)
        )

      profile_id
    end

    defp model_head!(ctx, ref \\ @model) do
      {:ok, [profile]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), ref)
      {:ok, head} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile.id)
      {:ok, blob} = Blob.parse(head.resolved_policy)
      {:ok, ingress} = Blob.ingress(blob, ref)
      {head, ingress.vault}
    end

    # The server's own context a boot's seed sync runs under: no person.
    defp seed(ctx),
      do: Sanctum.Context.internal(user_id: "_seed", athanor_id: ctx.athanor_id, scope: :athanor)

    # Run `fun` once, right after the walk's first read of `table`: for
    # the shares at a first mint, the administrator's shares, before the
    # mint's transaction locks the one it binds; for the binding rows, the
    # head's, before a revision reads the share or entry it keeps.
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

    # A store gone from under the walk, and back.
    defp away!(table),
      do: Arca.Repo.query!("ALTER TABLE #{table} RENAME TO #{table}_unavailable")

    defp back!(table),
      do: Arca.Repo.query!("ALTER TABLE #{table}_unavailable RENAME TO #{table}")

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
    # bootstrap, binds `bound` (`{:share, share_id}` or
    # `{:instance, entry_id}`) at `digest` in the ingress's default slot,
    # standing: its one binding row, whole.
    defp assert_bound!(ctx, bound, digest, revision) do
      {head, refs} = head_rows!(ctx)
      granted_by = if ctx.auth_method == :system, do: "system:bootstrap", else: ctx.user_id

      assert {head.revision, head.granted_via, head.granted_by} ==
               {revision, "bootstrap", granted_by}

      {scope, share_id, instance_entry_id} =
        case bound do
          {:share, id} -> {"share", id, nil}
          {:instance, id} -> {"instance", nil, id}
        end

      assert refs == [
               %{
                 consent_id: head.id,
                 athanor_id: ctx.athanor_id,
                 binding_key: "#{@model}|@ingress|default",
                 scope: scope,
                 vault_entry_id: nil,
                 instance_entry_id: instance_entry_id,
                 share_id: share_id,
                 via_label: nil,
                 binding_digest: digest,
                 lifetime_kind: "standing",
                 expires_at: nil,
                 consumed_by_root: nil
               }
             ]
    end

    defp assert_shared!(ctx, %{share: share, entry: entry}, revision \\ 1),
      do: assert_bound!(ctx, {:share, share.id}, entry.binding_digest, revision)

    defp assert_offered!(ctx, entry, revision),
      do: assert_bound!(ctx, {:instance, entry.id}, entry.binding_digest, revision)

    defp assert_unbound!(ctx) do
      assert {head, nil} = model_head!(ctx)
      assert head.vault_refs == []
    end

    # A revoke of the share `share_id` landing right after the boot's
    # revision read the share's facts and before its transaction locks the
    # share: run from the walk's first read of a share, once.
    def revoke_share_after_facts(_event, _measurements, meta, %{test: test, revoke: revoke}) do
      if self() == test and meta[:source] == "shares" and Process.get(:share_revoked) == nil do
        Process.put(:share_revoked, Task.async(revoke) |> Task.await(30_000))
      end
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

    # `person`, signed in to the shared test athanor, a group, where the
    # old store's heads are revised; Ana, signed in to her own athanor,
    # where a first sign-in binds a share; the platform administrator.
    setup %{ctx: ctx} do
      {person, _user} = Sanctum.TestContext.person!(ctx)
      ana = ShareFixtures.person!("Ana")
      {:ok, person: person, ana: ana.ctx, admin: administrator!()}
    end

    # -------------------------------------------------------------------------
    # The first mint
    # -------------------------------------------------------------------------

    test "a newly provisioned athanor binds the administrator's share to everyone whose " <>
           "source fits, whatever its label, and never a member's share to everyone",
         %{ana: ana, admin: admin} do
      ship_model!(ana)
      shared = share!(admin, %{provider_hint: "x.ai"})
      _elsewhere = share!(admin, %{destination: @anthropic_inference})
      # A member's share to everyone that fits, the newest of all: never a
      # first sign-in's candidate.
      _member = share!(ShareFixtures.person!("Sam"))

      assert {:ok, %{minted: minted}} = Bootstrap.run(ana)
      assert @model in minted

      {head, vault} = model_head!(ana)

      # The default slot, scoped share, naming the share at the digest its
      # source derives, standing; a recorded bootstrap revision like every
      # machine mint.
      assert %{entry_id: id, scope: "share", binding_key: key} = vault
      assert id == shared.share.id
      assert vault.binding_digest == shared.entry.binding_digest
      assert key == "#{@model}|@ingress|default"
      assert vault.attach.name == "Authorization"
      refute Map.has_key?(vault, :named)

      assert [%{share_id: ^id, scope: "share", lifetime_kind: "standing"}] = head.vault_refs
      assert_shared!(ana, shared)
    end

    test "two of the administrator's shares that fit bind the newest", %{ana: ana, admin: admin} do
      ship_model!(ana)
      _older = share!(admin)
      newest = share!(admin, %{provider_hint: ""})

      assert Bootstrap.run(ana) == {:ok, %{minted: [@model], revised: [], skipped: []}}
      assert_shared!(ana, newest)
    end

    test "with no share of the administrator's that fits, the catalyst is minted without one, " <>
           "and nothing is skipped",
         %{ana: ana, admin: admin} do
      ship_model!(ana)
      _elsewhere = share!(admin, %{destination: @anthropic_inference})

      assert Bootstrap.run(ana) == {:ok, %{minted: [@model], revised: [], skipped: []}}
      assert_unbound!(ana)
    end

    test "a server-side mint has no person and binds nothing", %{ana: ana, admin: admin} do
      ship_model!(ana)
      share!(admin)

      assert {:ok, %{minted: minted}} = Bootstrap.run(seed(ana))
      assert @model in minted
      assert_unbound!(ana)
    end

    # A share is bound only in a person's own athanor.
    test "a first sign-in to a group athanor binds no share, and mints the catalyst",
         %{person: person, admin: admin} do
      ship_model!(person)
      share!(admin)

      assert Bootstrap.run(person) == {:ok, %{minted: [@model], revised: [], skipped: []}}
      assert_unbound!(person)
    end

    # The first mint is the only one that binds the share, so a read of
    # the administrator's shares that could not answer is never nothing
    # offered: minted without the share, the catalyst's person would have
    # to connect a key over one that is there for them.
    @tag :capture_log
    test "an outage reading the administrator's shares mints nothing for the catalyst, and a " <>
           "run once the store answers mints it bound",
         %{ana: ana, admin: admin} do
      ship_model!(ana)
      shared = share!(admin)

      away!("shares")
      {unanswered, log} = with_log(fn -> Bootstrap.run(ana) end)
      back!("shares")

      assert unanswered ==
               {:ok, %{minted: [], revised: [], skipped: [{@model, @shares_unavailable}]}}

      assert log =~ "#{@model} skipped: Shares could not answer (:unavailable)"
      assert no_profile?(ana)

      assert Bootstrap.run(ana) == {:ok, %{minted: [@model], revised: [], skipped: []}}
      assert_shared!(ana, shared)
    end

    # The share is read once; a revoke landing after that read meets the
    # mint's lock, which refuses the share, so nothing is minted, and the
    # next run, no longer offered it, mints the catalyst without it.
    test "a share revoked after the walk read it is refused under the mint's lock, nothing is " <>
           "minted, and the next run mints the catalyst without it",
         %{ana: ana, admin: admin} do
      ship_model!(ana)
      shared = share!(admin)

      after_read!("shares", fn ->
        {:ok, _revoked} =
          Arca.Shares.revoke(
            admin.actor,
            shared.share.id,
            Sanctum.Vault.blocked_profile_status()
          )
      end)

      assert Bootstrap.run(ana) ==
               {:ok,
                %{minted: [], revised: [], skipped: [{@model, {:share_unavailable, "revoked"}}]}}

      assert no_profile?(ana)
      assert Bootstrap.run(ana) == {:ok, %{minted: [@model], revised: [], skipped: []}}
      assert_unbound!(ana)
    end

    # A context that is not the server's but names no person has nothing
    # offered to it, as `Sanctum.Consent.Plan` reads the same refusal: the
    # read answered, and the catalyst is minted without a share.
    test "a context with no person is offered nothing, and the catalyst is minted without a " <>
           "binding",
         %{ana: ana, admin: admin} do
      ship_model!(ana)
      share!(admin)
      no_person = %{ana | user_id: nil}

      assert {:error, :anonymous_denied} = Sanctum.Shares.administrator_shares(no_person)
      assert Bootstrap.run(no_person) == {:ok, %{minted: [@model], revised: [], skipped: []}}
      assert_unbound!(ana)
    end

    test "an anonymous context is offered nothing, and the catalyst is minted without a binding",
         %{ana: ana, admin: admin} do
      ship_model!(ana)
      share!(admin)
      anonymous = %{ana | anonymous: true}

      assert {:error, :anonymous_denied} = Sanctum.Shares.administrator_shares(anonymous)
      assert Bootstrap.run(anonymous) == {:ok, %{minted: [@model], revised: [], skipped: []}}
      assert_unbound!(ana)
    end

    # A server-side mint has no person to read the offer as, so it reads
    # none, and an outage of the store holds nothing up.
    test "a server-side mint under a shares outage reads no offer and mints without a binding",
         %{ana: ana, admin: admin} do
      ship_model!(ana)
      share!(admin)

      away!("shares")
      answer = Bootstrap.run(seed(ana))
      back!("shares")

      assert answer == {:ok, %{minted: [@model], revised: [], skipped: []}}
      assert_unbound!(ana)
    end

    # The shape derivation refuses a source whose stored manifest does not
    # decode, by the same term: whichever read meets it first, the person
    # is told the manifest is damaged, and nothing is minted without the
    # share there is for them.
    @tag :capture_log
    test "a catalyst whose stored manifest does not decode is skipped as damaged, and nothing " <>
           "is minted",
         %{ana: ana, admin: admin} do
      component = ship_model!(ana)
      share!(admin)
      set_manifest!(component, "{not json")

      assert Bootstrap.run(ana) ==
               {:ok,
                %{minted: [], revised: [], skipped: [{@model, {:corrupt, {:manifest, @model}}}]}}

      assert no_profile?(ana)

      assert Prima.Refusal.message({:corrupt, {:manifest, @model}}) ==
               "The stored manifest is damaged."
    end

    # The walk keeps the row it read. Repairing storage before its later
    # reads must not turn that unreadable snapshot into an unbound mint.
    @tag :capture_log
    test "a mint that read a damaged manifest skips even when storage is repaired before its " <>
           "later reads, and the next run mints it bound",
         %{ana: ana, admin: admin} do
      component = ship_model!(ana)
      shared = share!(admin)
      set_manifest!(component, "{not json")
      after_read!("components", fn -> set_manifest!(component, component.manifest) end)

      assert Bootstrap.run(ana) ==
               {:ok,
                %{minted: [], revised: [], skipped: [{@model, {:corrupt, {:manifest, @model}}}]}}

      assert no_profile?(ana)
      assert Bootstrap.run(ana) == {:ok, %{minted: [@model], revised: [], skipped: []}}
      assert_shared!(ana, shared)
    end

    test "a claim taken over after the administrator's shares are read mints no profile", %{
      ana: ana,
      admin: admin
    } do
      ship_model!(ana)
      share!(admin)
      actor = Sanctum.Context.actor(ana)
      test = self()

      {:ok, stale} =
        Arca.ProvisioningClaims.claim(actor, "boot_elsewhere/own_walk", "sign_in", 1, :none)

      # A claim as provisioning hands it on: with the slot it was taken under.
      stale = Map.put(stale, :slot, :none)

      after_read!("shares", fn ->
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

      assert Bootstrap.run(ana, stale) == {:error, :claim_lost}
      assert_receive {:claim_taken, successor}
      assert successor.fence == stale.fence + 1
      assert no_profile?(ana)
      assert Arca.ProvisioningClaims.current(actor) == {:ok, successor}
    end

    test "an athanor provisioned before the administrator shared a key is not revised under " <>
           "its people, and the share is the suggestion at the next grant",
         %{ana: ana, admin: admin} do
      ship_model!(ana)
      {:ok, _} = Bootstrap.run(ana)
      {before, nil} = model_head!(ana)

      shared = share!(admin)

      assert {:ok, %{minted: [], revised: [], skipped: skipped}} = Bootstrap.run(ana)
      assert {@model, :already_bootstrapped} in skipped
      {head, vault} = model_head!(ana)
      assert head.id == before.id and vault == nil

      {:ok, plan} = Sanctum.Consent.Plan.plan(ana, %{ref: @model})
      row = Enum.find(plan.needs, &(&1.need == "api_key"))
      assert row.suggested == %{share_id: shared.share.id}
      assert row.source == "share"
    end

    # -------------------------------------------------------------------------
    # Revisions of a head binding a share
    # -------------------------------------------------------------------------

    test "a revision under a person keeps the head's share while it is offered at its digest, " <>
           "and binds none once its source was rebound",
         %{ana: ana, admin: admin} do
      ship_model!(ana)
      shared = share!(admin)
      {:ok, _} = Bootstrap.run(ana)

      # The release moves the shape: the bootstrap-only head is revised,
      # and the share it bound, unchanged and still offered, stays bound.
      ship_model!(ana, "1.1.0", %{"limits" => %{"timeout" => "2m"}})
      assert Bootstrap.run(ana) == {:ok, %{minted: [], revised: [@model], skipped: []}}
      assert_shared!(ana, shared, 2)

      # Rebound since: the next revision binds none, and adds none back.
      moved = ShareFixtures.rebind!(admin, shared.entry)
      refute moved == shared.entry.binding_digest

      ship_model!(ana, "1.2.0", %{"limits" => %{"timeout" => "3m"}})
      # The rebind blocked the profile; a bootstrap revision is still the
      # seed's to write over a bootstrap-only head.
      assert Bootstrap.run(ana) == {:ok, %{minted: [], revised: [@model], skipped: []}}
      {head, _vault} = model_head!(ana)
      assert head.revision == 3
      assert_unbound!(ana)
    end

    test "a revision under a person binds none once the share is revoked",
         %{ana: ana, admin: admin} do
      ship_model!(ana)
      shared = share!(admin)
      {:ok, _} = Bootstrap.run(ana)

      {:ok, _revoked} =
        Arca.Shares.revoke(admin.actor, shared.share.id, Sanctum.Vault.blocked_profile_status())

      ship_model!(ana, "1.1.0", %{"limits" => %{"timeout" => "2m"}})
      assert Bootstrap.run(ana) == {:ok, %{minted: [], revised: [@model], skipped: []}}
      {head, _vault} = model_head!(ana)
      assert head.revision == 2
      assert_unbound!(ana)
    end

    # A revision under a person keeps the head's share only once it read
    # it: a read the store could not answer keeps the head as it stands,
    # never revised without the share it bound.
    @tag :capture_log
    test "a revision under a person that cannot read the share its head binds keeps the head, " <>
           "and a run once the store answers revises it bound",
         %{ana: ana, admin: admin} do
      ship_model!(ana)
      shared = share!(admin)
      {:ok, _} = Bootstrap.run(ana)
      held = head_rows!(ana)

      ship_model!(ana, "1.1.0", %{"limits" => %{"timeout" => "2m"}})
      after_read!("consent_vault_refs", fn -> away!("shares") end)
      {unanswered, log} = with_log(fn -> Bootstrap.run(ana) end)
      back!("shares")

      assert unanswered ==
               {:ok, %{minted: [], revised: [], skipped: [{@model, @shares_unavailable}]}}

      assert log =~ "#{@model} skipped: Shares could not answer (:unavailable)"
      assert head_rows!(ana) == held

      assert Bootstrap.run(ana) == {:ok, %{minted: [], revised: [@model], skipped: []}}
      assert_shared!(ana, shared, 2)
    end

    test "a boot's revision with no person carries the head's share as held, is refused by a " <>
           "revoke landing after its read, and then binds none",
         %{ana: ana, admin: admin} do
      ship_model!(ana)
      shared = share!(admin)
      {:ok, _} = Bootstrap.run(ana)
      {first, bound} = model_head!(ana)
      [first_row] = first.vault_refs

      # A boot's seed sync runs under the server's own context: no person
      # to read the offer as. The release moves the shape, and the revision
      # carries the share, its digest, its key and its lifetime unchanged.
      ship_model!(ana, "1.1.0", %{"limits" => %{"timeout" => "2m"}})
      assert Bootstrap.run(seed(ana)) == {:ok, %{minted: [], revised: [@model], skipped: []}}
      {head, vault} = model_head!(ana)
      assert head.revision == 2

      assert %{entry_id: id, binding_digest: digest, binding_key: key, scope: "share"} = vault

      assert {id, digest, key} ==
               {shared.share.id, shared.entry.binding_digest, bound.binding_key}

      assert vault.destination == bound.destination
      assert vault.attach.name == "Authorization"

      assert [row] = head.vault_refs

      assert Map.take(row, [:binding_key, :share_id, :binding_digest, :scope]) ==
               Map.take(first_row, [:binding_key, :share_id, :binding_digest, :scope])

      assert {row.lifetime_kind, row.expires_at} ==
               {first_row.lifetime_kind, first_row.expires_at}

      assert_bound!(seed(ana), {:share, shared.share.id}, shared.entry.binding_digest, 2)

      # A revoke landing after the revision read the share as active: the
      # revision's lock refuses the share, nothing is written, and the boot
      # reports the source skipped with the refusal.
      ship_model!(ana, "1.2.0", %{"limits" => %{"timeout" => "3m"}})
      handler = {__MODULE__, :revoke_share_after_facts, System.unique_integer([:positive])}

      revoke = fn ->
        Arca.Shares.revoke(admin.actor, shared.share.id, Sanctum.Vault.blocked_profile_status())
      end

      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          &__MODULE__.revoke_share_after_facts/4,
          %{test: self(), revoke: revoke}
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, %{revised: [], skipped: skipped}} = Bootstrap.run(seed(ana))
      :telemetry.detach(handler)
      assert {:ok, %{blocked: [_blocked]}} = Process.get(:share_revoked)
      assert {@model, {:share_unavailable, "revoked"}} in skipped
      {after_revoke, _vault} = model_head!(ana)
      assert after_revoke.id == head.id

      # Read as revoked, the share is carried no further: the next boot's
      # revision binds none.
      assert Bootstrap.run(seed(ana)) == {:ok, %{minted: [], revised: [@model], skipped: []}}
      {unbound, _vault} = model_head!(ana)
      assert unbound.revision == 3
      assert_unbound!(ana)
    end

    test "a boot's revision with no person carries nothing once the share's source was " <>
           "rebound past the head's digest",
         %{ana: ana, admin: admin} do
      ship_model!(ana)
      shared = share!(admin)
      {:ok, _} = Bootstrap.run(ana)

      # Still active, its destination still covering the need, but no
      # longer at the digest the head bound: the revision binds none.
      ShareFixtures.rebind!(admin, shared.entry)
      ship_model!(ana, "1.1.0", %{"limits" => %{"timeout" => "2m"}})
      assert Bootstrap.run(seed(ana)) == {:ok, %{minted: [], revised: [@model], skipped: []}}
      {head, _vault} = model_head!(ana)
      assert head.revision == 2
      assert_unbound!(ana)
    end

    test "a boot's revision with no person carries nothing to a release whose need calls a " <>
           "host the share's source misses",
         %{ana: ana, admin: admin} do
      ship_model!(ana)
      share!(admin)
      {:ok, _} = Bootstrap.run(ana)

      ship_model!(ana, "1.1.0", %{}, ["api.anthropic.com"])
      assert Bootstrap.run(seed(ana)) == {:ok, %{minted: [], revised: [@model], skipped: []}}
      {head, _vault} = model_head!(ana)
      assert head.revision == 2
      assert_unbound!(ana)
    end

    # A boot that cannot read the share decides nothing about it.
    @tag :capture_log
    test "a boot's revision with no person under a shares outage keeps the head, and a boot " <>
           "once the store answers carries the share",
         %{ana: ana, admin: admin} do
      ship_model!(ana)
      shared = share!(admin)
      {:ok, _} = Bootstrap.run(ana)
      held = head_rows!(ana)

      ship_model!(ana, "1.1.0", %{"limits" => %{"timeout" => "2m"}})
      away!("shares")
      {unanswered, log} = with_log(fn -> Bootstrap.run(seed(ana)) end)
      back!("shares")

      assert unanswered ==
               {:ok, %{minted: [], revised: [], skipped: [{@model, @shares_unavailable}]}}

      assert log =~ "#{@model} skipped: Shares could not answer (:unavailable)"
      assert head_rows!(ana) == held

      assert Bootstrap.run(seed(ana)) == {:ok, %{minted: [], revised: [@model], skipped: []}}
      assert_bound!(seed(ana), {:share, shared.share.id}, shared.entry.binding_digest, 2)
    end

    test "a boot's revision of a head whose share binding has no ref row is the profile " <>
           "damaged, and the head is kept",
         %{ana: ana, admin: admin} do
      ship_model!(ana)
      share!(admin)
      {:ok, _} = Bootstrap.run(ana)
      profile_id = head_profile_id(ana)
      {head, [_bound]} = head_rows!(ana)
      drop_refs!(head.id)

      ship_model!(ana, "1.1.0", %{"limits" => %{"timeout" => "2m"}})

      assert Bootstrap.run(seed(ana)) ==
               {:ok,
                %{
                  minted: [],
                  revised: [],
                  skipped: [{@model, {:corrupt, {:profile, profile_id}}}]
                }}

      assert head_rows!(ana) == {head, []}
    end

    # -------------------------------------------------------------------------
    # Revisions of a head binding an instance entry
    # -------------------------------------------------------------------------

    # A revision under a person keeps the head's entry only once it read
    # it: a binding read the store could not answer keeps the head as it
    # stands, never revised without the entry it bound.
    @tag :capture_log
    test "a revision under a person that cannot read the entry its head binds keeps the head, " <>
           "and a run once the store answers revises it bound",
         %{person: person} do
      ship_model!(person)
      offered = offer!()
      instance_head!(person, offered)
      held = head_rows!(person)

      # The release moves the shape; the store goes once the head is read.
      ship_model!(person, "1.1.0", %{"limits" => %{"timeout" => "2m"}})
      after_read!("consent_vault_refs", fn -> away!("instance_entries") end)
      {unanswered, log} = with_log(fn -> Bootstrap.run(person) end)
      back!("instance_entries")

      assert unanswered ==
               {:ok, %{minted: [], revised: [], skipped: [{@model, @instance_unavailable}]}}

      assert log =~ "#{@model} skipped: Instance entries could not answer (:database_error)"
      assert head_rows!(person) == held

      assert Bootstrap.run(person) == {:ok, %{minted: [], revised: [@model], skipped: []}}
      assert_offered!(person, offered, 2)
    end

    # A boot's revision carries the head's binding as the head holds it,
    # so a head it cannot read whole is damaged, not a head that bound
    # nothing: the source is skipped with the head kept.
    test "a boot's revision of a head whose policy does not parse is the profile damaged, " <>
           "and the head is kept",
         %{ctx: ctx, person: person} do
      ship_model!(person)
      profile_id = instance_head!(person, offer!())
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
        profile_id = instance_head!(person, offer!())
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
      profile_id = instance_head!(person, offer!())
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

    for mode <- [:person, :seed] do
      @tag :capture_log
      @tag revision_context: mode
      test "a #{mode} revision that read a damaged manifest keeps the whole head even when " <>
             "storage is repaired before its later reads",
           %{ctx: ctx, person: person, revision_context: mode} do
        ship_model!(person)
        offered = offer!()
        instance_head!(person, offered)
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

        assert_offered!(revision_ctx, offered, 2)
      end
    end

    test "a revision keeps the head's instance binding while it is offered at its digest, and " <>
           "binds none once it was rebound",
         %{person: person} do
      ship_model!(person)
      offered = offer!()
      instance_head!(person, offered)

      # The release moves the shape: the bootstrap-only head is revised,
      # and the entry it bound, unchanged and still offered, stays bound.
      ship_model!(person, "1.1.0", %{"limits" => %{"timeout" => "2m"}})
      assert {:ok, %{revised: [@model]}} = Bootstrap.run(person)
      {head, vault} = model_head!(person)
      assert head.revision == 2
      assert vault.entry_id == offered.id
      assert_offered!(person, offered, 2)

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

    test "a boot's revision with no person carries the head's instance binding as held, is " <>
           "refused by a revoke landing after its read, and then binds none",
         %{ctx: ctx, person: person} do
      ship_model!(person)
      offered = offer!()
      instance_head!(person, offered)
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

    test "a boot's revision carries nothing to a release whose need calls a host the entry " <>
           "misses",
         %{ctx: ctx, person: person} do
      ship_model!(person)
      offered = offer!()
      instance_head!(person, offered)
      {_first, bound} = model_head!(person)
      assert bound.entry_id == offered.id

      # The same need, now calling api.anthropic.com: the entry bound for
      # api.openai.com meets it no longer, and the revision binds none.
      ship_model!(person, "1.1.0", %{}, ["api.anthropic.com"])
      assert {:ok, %{revised: [@model]}} = Bootstrap.run(seed(ctx))
      {head, vault} = model_head!(person)
      assert head.revision == 2
      assert vault == nil and head.vault_refs == []
    end

    test "a boot's revision carries nothing once the entry was rebound past the head's digest",
         %{ctx: ctx, person: person} do
      ship_model!(person)
      offered = offer!()
      instance_head!(person, offered)
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

      # Still active and its destination still covering the need, but no
      # longer at the digest the head bound: the revision binds none.
      ship_model!(person, "1.1.0", %{"limits" => %{"timeout" => "2m"}})
      assert {:ok, %{revised: [@model]}} = Bootstrap.run(seed(ctx))
      {head, vault} = model_head!(person)
      assert head.revision == 2
      assert vault == nil and head.vault_refs == []
    end

    # -------------------------------------------------------------------------
    # The automatic field map
    # -------------------------------------------------------------------------

    @grok "catalyst:local.grok"
    @grok_unit Path.expand("../../../../../seed/components/catalysts/local/grok", __DIR__)
    @xai ~s({"hosts":["api.x.ai"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"})

    # The newest Grok catalyst the seed ships: its need and its caps,
    # released at `version` with `limits` over its own.
    defp ship_grok!(ctx, version \\ nil, limits \\ %{}) do
      newest = @grok_unit |> File.ls!() |> Compendium.Semver.sort_desc() |> hd()

      shipped =
        Path.join([@grok_unit, newest, "cyfr-manifest.json"]) |> File.read!() |> Jason.decode!()

      version = version || newest

      {:ok, component} =
        Arca.Test.UnitFixtures.ship_and_register!(ctx, "catalyst", "local", "grok", version,
          manifest:
            shipped
            |> Map.take(~w(name type publisher description needs caps))
            |> Map.put("version", version)
            |> update_in(["caps", "limits"], &Map.merge(&1, limits)),
          wasm: Cyfr.Test.Guests.wasm(:catalyst)
        )

      {component, shipped}
    end

    # A key of the administrator's with no label shared with everyone,
    # holding `field_names` and admitting POST under /v1/ on api.x.ai.
    defp share_xai!(admin, field_names) do
      share!(admin, %{
        provider_hint: "",
        field_names: Jason.encode!(field_names),
        destination: @xai
      })
    end

    test "provisioning binds the administrator's share at first sign-in with the automatic " <>
           "map, and a boot's revision to a new release keeps it",
         %{ana: ana, admin: admin} do
      {first_release, shipped} = ship_grok!(ana)
      assert %{"api_key" => %{"fields" => ["GROK_API_KEY"]}} = shipped["needs"]
      shared = share_xai!(admin, ["API key"])

      # The need's one field and the source's one field: the automatic map.
      assert {:ok, %{minted: minted}} = Bootstrap.run(ana)
      assert @grok in minted
      {first, bound} = model_head!(ana, @grok)
      assert first.revision == 1
      assert {bound.scope, bound.entry_id} == {"share", shared.share.id}
      assert bound.projection == %{fields: %{"GROK_API_KEY" => "API key"}, scopes: []}

      # A new release whose limits differ moves the shape, so a boot's seed
      # sync, with no person, revises the bootstrap-only head rather than
      # skipping it as already bootstrapped.
      refute shipped["caps"]["limits"]["timeout"] == "7m"
      new_version = Version.parse!(first_release.version) |> Map.update!(:patch, &(&1 + 1))
      ship_grok!(ana, to_string(new_version), %{"timeout" => "7m"})

      assert {:ok, %{revised: [@grok]}} = Bootstrap.run(seed(ana))
      {revised, kept} = model_head!(ana, @grok)
      assert revised.revision == 2
      refute revised.shape_digest == first.shape_digest

      assert {kept.entry_id, kept.binding_digest} ==
               {shared.share.id, shared.entry.binding_digest}

      assert kept.projection == %{fields: %{"GROK_API_KEY" => "API key"}, scopes: []}
    end

    test "provisioning binds nothing where the share's fields leave the need unmapped, and " <>
           "still mints the consent",
         %{ana: ana, admin: admin} do
      ship_grok!(ana)
      share_xai!(admin, ["key id", "secret"])

      {answer, log} = with_log(fn -> Bootstrap.run(ana) end)

      assert {:ok, %{minted: minted, skipped: []}} = answer
      assert @grok in minted
      assert log =~ ~s(no key bound for #{@grok}: {:fields_unmapped, "api_key"})
      {head, vault} = model_head!(ana, @grok)
      assert head.revision == 1
      assert vault == nil and head.vault_refs == []
    end

    test "an older share whose fields the need maps binds where the newest's leave it unmapped",
         %{ana: ana, admin: admin} do
      ship_grok!(ana)
      mapped = share_xai!(admin, ["API key"])
      _newest = share_xai!(admin, ["key id", "secret"])

      assert {:ok, %{minted: minted}} = Bootstrap.run(ana)
      assert @grok in minted
      {_head, bound} = model_head!(ana, @grok)
      assert {bound.scope, bound.entry_id} == {"share", mapped.share.id}
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
