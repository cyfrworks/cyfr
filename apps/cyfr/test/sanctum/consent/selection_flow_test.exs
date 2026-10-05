# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.SelectionFlowTest do
  @moduledoc """
  A person's consent selects which of a dependency's profiles lends its
  key: the plan offers the dependency's bound profiles, the commit pins
  the lender's binding digest and the digest covers the choice, the
  loaded authority carries the lender's entry on that edge, and two
  sources selecting two profiles of one dependency run it with two keys.
  A run whose consent, or a lender of it, the store cannot answer or
  cannot decode is refused in a sentence of its own.
  """

  use ExUnit.Case, async: false

  require Ecto.Query

  alias Prima.Authority.Blob
  alias Prima.Authority.Transition
  alias Sanctum.Consent.Commit
  alias Sanctum.Consent.Plan
  alias Sanctum.Providers.Profile
  alias Prima.Test.AuthorityFixtures, as: Fixtures

  @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))
  @dep "reagent:local.sel-dep"
  @role_a "reagent:local.sel-role-a"
  @role_b "reagent:local.sel-role-b"
  @root "reagent:local.sel-root"

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "consent_selection_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    ctx = Sanctum.TestContext.local(:prism)

    # The dependency declares one credential need; each source depends on it.
    publish!(ctx, "sel-dep", %{
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:example.com",
          "reason" => "to call the example API",
          "required" => true,
          "fields" => ["KEY", "ORG"]
        }
      },
      "caps" => %{"egress" => %{"domains" => ["api.example.com"]}}
    })

    for name <- ~w(sel-source sel-source-two) do
      publish!(ctx, name, %{"dependencies" => %{"static" => [%{"ref" => @dep}]}})
    end

    {:ok, ctx: ctx}
  end

  defp publish!(ctx, name, manifest_extra) do
    manifest =
      Map.merge(%{"name" => name, "version" => "1.0.0", "type" => "reagent"}, manifest_extra)

    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: name,
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(manifest)
      })

    component
  end

  # An entry of the provider the dependency's need names; the need
  # declares no attach rule, so the dependency reads the key itself and
  # the entry is disclosed.
  defp entry!(ctx, name, fields) do
    {:ok, view} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: name,
        kind: "api_key",
        provider_hint: "example.com",
        fields: fields,
        destination: %{"hosts" => ["api.example.com"]},
        disclose: true
      })

    view
  end

  defp walk!(ctx, ref, decisions_over) do
    {:ok, plan} = Plan.plan(ctx, Map.take(Map.merge(%{ref: ref}, decisions_over), [:ref, :label]))
    decisions = Map.merge(%{ref: ref}, decisions_over)
    {:ok, preview} = Commit.preview(ctx, decisions)

    result =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    {result, preview}
  end

  # The dependency's profiles: "default" bound to one key, "work" to another.
  defp lenders!(ctx) do
    home = entry!(ctx, "home key", %{"KEY" => "k-home", "ORG" => "o-home"})
    work = entry!(ctx, "work key", %{"KEY" => "k-work", "ORG" => "o-work"})

    {{:ok, %{profile_id: default}}, _} =
      walk!(ctx, @dep, %{bindings: [%{need: "api_key", entry_id: home.id}]})

    {{:ok, %{profile_id: work_profile}}, _} =
      walk!(ctx, @dep, %{
        label: "work",
        bindings: [%{need: "api_key", entry_id: work.id, fields: ["KEY"]}]
      })

    %{default: default, work: work_profile, home_entry: home, work_entry: work}
  end

  defp edge_vault(ctx, source_ref) do
    {:ok, authority} = Crucible.authority_for(ctx, :default, source_ref)
    {:ok, edge} = Blob.lookup_edge(authority.policy, source_ref, @dep, "")
    edge.vault
  end

  # What a dispense under `source_ref`'s authority is made for: the profile
  # and consent it is pinned to, and a root of its own.
  defp edge_use(ctx, source_ref) do
    {:ok, authority} = Crucible.authority_for(ctx, :default, source_ref)

    %{
      root_execution_id: "exec_selection_flow",
      profile_id: authority.profile_id,
      consent_id: authority.consent_id
    }
  end

  test "the plan offers the dependency's bound profiles as lenders", %{ctx: ctx} do
    lenders = lenders!(ctx)
    {:ok, plan} = Plan.plan(ctx, %{ref: "reagent:local.sel-source"})

    assert [
             %{from: "reagent:local.sel-source", dep: @dep, needs: [need], candidates: candidates}
           ] = plan.dependency_needs

    assert need.need == "api_key" and need.reason =~ "example API"

    assert Enum.sort_by(candidates, & &1.label) == [
             %{
               profile_id: lenders.default,
               label: "default",
               source: "own",
               entry_id: lenders.home_entry.id,
               entry_name: "home key",
               fields: ["KEY", "ORG"],
               scopes: []
             },
             %{
               profile_id: lenders.work,
               label: "work",
               source: "own",
               entry_id: lenders.work_entry.id,
               entry_name: "work key",
               fields: ["KEY"],
               scopes: []
             }
           ]
  end

  @inst_dep "reagent:local.sel-inst-dep"
  @inst_source "reagent:local.sel-inst-source"

  # A dependency whose need attaches an example.com key, so an instance
  # entry can meet it, and a source that depends on it.
  defp instance_lending!(ctx) do
    publish!(ctx, "sel-inst-dep", %{
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:example.com",
          "reason" => "to call the example API",
          "required" => true,
          "fields" => ["KEY"],
          "attach" => %{
            "in" => "header",
            "name" => "Authorization",
            "template" => "Bearer {value}"
          }
        }
      },
      "caps" => %{"egress" => %{"domains" => ["api.example.com"], "methods" => ["POST"]}}
    })

    publish!(ctx, "sel-inst-source", %{"dependencies" => %{"static" => [%{"ref" => @inst_dep}]}})

    {:ok, offered} =
      Arca.InstanceEntries.put(Arca.Test.Actor.platform(), %{
        name: "company example key",
        kind: "api_key",
        provider_hint: "example.com",
        field_names: ~s(["KEY"]),
        destination:
          ~s({"hosts":["api.example.com"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"}),
        sealed_payload: "sealed",
        binding_digest: "sha256:lent-#{System.unique_integer([:positive])}",
        audience: "everyone",
        created_by: "usr_admin"
      })

    offered
  end

  test "a dependency's profile bound to an offered instance entry lends it: the plan, the " <>
         "preview, the commit and the readiness read it as an instance entry",
       %{ctx: ctx} do
    {person, _user} = Sanctum.TestContext.person!(ctx)
    offered = instance_lending!(ctx)

    {{:ok, _}, _} =
      walk!(person, @inst_dep, %{bindings: [%{need: "api_key", instance_entry_id: offered.id}]})

    {:ok, plan} = Plan.plan(person, %{ref: @inst_source})
    assert [%{dep: @inst_dep, candidates: [lender]}] = plan.dependency_needs
    assert %{label: "default", source: "instance", entry_id: id, entry_name: name} = lender
    assert {id, name} == {offered.id, offered.name}

    {{:ok, %{profile_id: profile_id}}, preview} =
      walk!(person, @inst_source, %{selections: [%{dep: @inst_dep, label: "default"}]})

    assert [%{"node" => @inst_source, "values" => values}] =
             Enum.filter(preview.rows, &(&1["kind"] == "credential"))

    assert values["source"] == "instance"
    assert values["name"] == offered.name
    assert values["label"] == "default"
    assert values["disclosed"] == false

    # The borrower's row is the selection, both identities kept: its own
    # key and label here, the lender's binding resolved at load.
    {:ok, head} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(person), profile_id)

    assert [%{via_label: "default", vault_entry_id: nil, instance_entry_id: nil}] =
             head.vault_refs

    assert %{entry_id: ^id, scope: "instance", lender: %{profile_id: _}} =
             edge_vault_of(person, @inst_source, @inst_dep)

    section = Compendium.ConsentSetupPlan.section(person, @inst_source)
    assert section.ready
    assert [%{entry_id: ^id, satisfied: true, detail: detail}] = section.needs
    assert detail =~ "instance entry"

    # Offered to the person no longer (a narrowed audience blocks no
    # profile), the lent entry is read live and is not ready.
    {someone_else, _user} =
      Sanctum.TestContext.person!(ctx, %{
        id:
          Sanctum.Auth.Identity.builtin_key(
            :github,
            "someone-else-#{System.unique_integer([:positive])}"
          ),
        email: "someone-else-#{System.unique_integer([:positive])}@example.com"
      })

    :ok =
      Arca.InstanceEntries.set_audience(
        Arca.Test.Actor.platform(),
        offered.id,
        %{audience: "everyone", members: []},
        %{audience: "listed", members: [someone_else.user_id]}
      )

    section = Compendium.ConsentSetupPlan.section(person, @inst_source)
    refute section.ready
    assert [%{satisfied: false, detail: narrowed}] = section.needs
    assert narrowed =~ "no longer offered to you"
  end

  test "a lent instance entry is refused to a person it is not offered to, and on a node its " <>
         "policy does not admit",
       %{ctx: ctx} do
    {person, _user} = Sanctum.TestContext.person!(ctx)

    {other, other_user} =
      Sanctum.TestContext.person!(ctx, %{
        id:
          Sanctum.Auth.Identity.builtin_key(
            :github,
            "other-#{System.unique_integer([:positive])}"
          ),
        email: "other-#{System.unique_integer([:positive])}@example.com"
      })

    offered = instance_lending!(ctx)

    {{:ok, _}, _} =
      walk!(person, @inst_dep, %{bindings: [%{need: "api_key", instance_entry_id: offered.id}]})

    selections = [%{dep: @inst_dep, label: "default"}]

    # Offered to the first person alone: the second may not borrow it.
    :ok =
      Arca.InstanceEntries.set_audience(
        Arca.Test.Actor.platform(),
        offered.id,
        %{audience: "everyone", members: []},
        %{audience: "listed", members: [person.user_id]}
      )

    refute other_user.id == person.user_id
    {:ok, plan} = Plan.plan(other, %{ref: @inst_source})
    assert [%{candidates: []}] = plan.dependency_needs

    assert {:error, {:not_offered, @inst_dep}} =
             Commit.preview(other, %{ref: @inst_source, selections: selections})

    # Its policy admits shipped nodes alone, and the dependency is the
    # person's own: no one may borrow it on that node.
    :ok =
      Arca.InstanceEntries.set_component_policy(
        Arca.Test.Actor.platform(),
        offered.id,
        "any",
        "shipped"
      )

    {:ok, plan} = Plan.plan(person, %{ref: @inst_source})
    assert [%{candidates: []}] = plan.dependency_needs

    assert {:error, {:component_not_admitted, @inst_dep}} =
             Commit.preview(person, %{ref: @inst_source, selections: selections})
  end

  @oauth_dep "reagent:local.sel-oauth-dep"
  @oauth_source "reagent:local.sel-oauth-source"
  @mail ~s({"hosts":["gmail.googleapis.com"],"methods":["GET"],"paths":["/gmail/"],"scheme":"https"})

  # A dependency whose one need attaches a Google token of exactly
  # `gmail.readonly`, and a source that depends on it.
  defp oauth_lending!(ctx) do
    publish!(ctx, "sel-oauth-dep", %{
      "needs" => %{
        "mail" => %{
          "type" => "oauth:google",
          "reason" => "to read your mail",
          "required" => true,
          "scopes" => ["gmail.readonly"],
          "attach" => %{"in" => "header", "name" => "Authorization"}
        }
      },
      "caps" => %{"egress" => %{"domains" => ["gmail.googleapis.com"], "methods" => ["GET"]}}
    })

    publish!(ctx, "sel-oauth-source", %{
      "dependencies" => %{"static" => [%{"ref" => @oauth_dep}]}
    })
  end

  # The dependency's default profile binds `binding`; the source borrows
  # it by label, and the borrowed edge carries the lender's scopes whole.
  defp lend_oauth!(person, binding) do
    {{:ok, _}, _} = walk!(person, @oauth_dep, %{bindings: [Map.put(binding, :need, "mail")]})

    selections = [%{dep: @oauth_dep, label: "default"}]

    # Naming a field the lender does not lend widens it, and an explicit
    # empty list names nothing: both are refused.
    assert {:error, {:selection_fields_unavailable, @oauth_dep, ["KEY"]}} =
             Commit.preview(person, %{
               ref: @oauth_source,
               selections: [%{dep: @oauth_dep, label: "default", fields: ["KEY"]}]
             })

    assert {:error, {:invalid_argument, _}} =
             Commit.preview(person, %{
               ref: @oauth_source,
               selections: [%{dep: @oauth_dep, label: "default", fields: []}]
             })

    {{:ok, %{profile_id: profile_id}}, preview} =
      walk!(person, @oauth_source, %{selections: selections})

    assert [%{"values" => values}] = Enum.filter(preview.rows, &(&1["kind"] == "credential"))
    assert values["scopes"] == ["gmail.readonly"] and values["fields"] == []

    {:ok, head} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(person), profile_id)
    assert [%{via_label: "default"}] = head.vault_refs

    # Loaded, the borrowed edge carries the lender's scopes whole.
    assert %{projection: %{scopes: ["gmail.readonly"], fields: []}, lender: %{}} =
             edge_vault_of(person, @oauth_source, @oauth_dep)

    values
  end

  test "an OAuth binding is lent by its scopes: an offered instance entry", %{ctx: ctx} do
    {person, _user} = Sanctum.TestContext.person!(ctx)
    oauth_lending!(ctx)

    {:ok, offered} =
      Arca.InstanceEntries.put(Arca.Test.Actor.platform(), %{
        name: "company mail",
        kind: "oauth",
        provider_hint: "google",
        oauth_scopes: ~s(["gmail.readonly"]),
        destination: @mail,
        sealed_payload: "sealed",
        binding_digest: "sha256:mail-#{System.unique_integer([:positive])}",
        audience: "everyone",
        created_by: "usr_admin"
      })

    values = lend_oauth!(person, %{instance_entry_id: offered.id})
    assert values["source"] == "instance" and values["name"] == offered.name
  end

  test "an OAuth binding is lent by its scopes: the athanor's own entry", %{ctx: ctx} do
    {person, _user} = Sanctum.TestContext.person!(ctx)
    oauth_lending!(ctx)

    {:ok, own} =
      Sanctum.TestContext.create_vault(person, %{
        name: "my mail",
        kind: "oauth",
        provider_hint: "google",
        oauth: %{"access_token" => "t"},
        oauth_scopes: ["gmail.readonly"],
        destination: %{"hosts" => ["gmail.googleapis.com"]}
      })

    values = lend_oauth!(person, %{entry_id: own.id})
    assert values["source"] == "own" and values["name"] == "my mail"
  end

  defp edge_vault_of(ctx, source_ref, dep) do
    {:ok, authority} = Crucible.authority_for(ctx, :default, source_ref)
    {:ok, edge} = Blob.lookup_edge(authority.policy, source_ref, dep, "")
    edge.vault
  end

  test "two sources select two profiles of one dependency and run it with two keys", %{
    ctx: ctx
  } do
    lenders = lenders!(ctx)

    {{:ok, %{profile_id: _}}, preview} =
      walk!(ctx, "reagent:local.sel-source", %{
        selections: [%{dep: @dep, label: "default"}]
      })

    # The lent key is a typed row on the source, on the edge into the
    # dependency, naming the entry, its fields and the lending label.
    borrower_key = "reagent:local.sel-source|#{@dep}|default"

    assert [
             %{
               "kind" => "credential",
               "node" => "reagent:local.sel-source",
               "narrowed" => false,
               "values" => %{
                 "name" => "home key",
                 "edge" => @dep,
                 "label" => "default",
                 "fields" => ["KEY", "ORG"],
                 "scopes" => [],
                 # The borrower's own binding, standing, chosen by the
                 # person: the lent entry is the athanor's default for the
                 # need's provider, which the plan suggests.
                 "source" => "own",
                 "binding_key" => ^borrower_key,
                 "suggested" => true,
                 "choice_required" => false,
                 "lifetime" => %{"kind" => "standing", "until" => nil}
               }
             }
           ] = Enum.filter(preview.rows, &(&1["kind"] == "credential"))

    {{:ok, _}, _} =
      walk!(ctx, "reagent:local.sel-source-two", %{
        selections: [%{dep: @dep, label: "work", fields: ["KEY"]}]
      })

    {:ok, home_row} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), lenders.home_entry.id)
    {:ok, home_digest} = Sanctum.VaultReader.binding_digest(home_row)

    home_id = lenders.home_entry.id
    work_id = lenders.work_entry.id

    assert %{
             entry_id: ^home_id,
             binding_digest: ^home_digest,
             projection: %{fields: ["KEY", "ORG"]},
             binding_key: ^borrower_key,
             lender: %{binding_key: lender_key}
           } =
             edge_vault(ctx, "reagent:local.sel-source")

    # Both identities: the borrower's binding where it sits, the lender's
    # on the dependency's own ingress.
    assert lender_key == "#{@dep}|@ingress|default"

    assert %{entry_id: ^work_id, projection: %{fields: ["KEY"], scopes: []}} =
             edge_vault(ctx, "reagent:local.sel-source-two")

    # The stored blob carries the selection, pinned, and references no entry
    # of its own: its row is the borrower's binding, naming the label it
    # borrows and the digest it pinned.
    {:ok, [profile]} =
      Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), "reagent:local.sel-source")

    {:ok, head} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile.id)

    assert [
             %{
               binding_key: ^borrower_key,
               scope: "athanor",
               via_label: "default",
               binding_digest: ^home_digest,
               vault_entry_id: nil,
               instance_entry_id: nil
             }
           ] = head.vault_refs

    {:ok, blob} = Blob.parse(head.resolved_policy)
    {:ok, edge} = Blob.lookup_edge(blob, "reagent:local.sel-source", @dep, "")
    assert %{via: %{label: "default", binding_digest: ^home_digest}} = edge.vault
  end

  test "the commit digest covers the selection", %{ctx: ctx} do
    _lenders = lenders!(ctx)
    {:ok, plain} = Commit.preview(ctx, %{ref: "reagent:local.sel-source"})

    {:ok, selected} =
      Commit.preview(ctx, %{
        ref: "reagent:local.sel-source",
        selections: [%{dep: @dep, label: "default"}]
      })

    {:ok, other} =
      Commit.preview(ctx, %{
        ref: "reagent:local.sel-source",
        selections: [%{dep: @dep, label: "work"}]
      })

    assert plain.commit_digest != selected.commit_digest
    assert selected.commit_digest != other.commit_digest
  end

  test "a selection names a dependency, an active owner profile of it that binds a key, and fields it lends",
       %{ctx: ctx} do
    lenders = lenders!(ctx)
    ref = "reagent:local.sel-source"

    assert {:error, {:selection_target_unknown, "reagent:local.nope"}} =
             Commit.preview(ctx, %{
               ref: ref,
               selections: [%{dep: "reagent:local.nope", label: "default"}]
             })

    assert {:error, {:selection_profile_unavailable, @dep, "nope"}} =
             Commit.preview(ctx, %{ref: ref, selections: [%{dep: @dep, label: "nope"}]})

    # A profile of the dependency that binds nothing lends nothing.
    {{:ok, %{profile_id: _unbound}}, _} = walk!(ctx, @dep, %{label: "empty"})

    assert {:error, {:selection_unbound, @dep, "empty"}} =
             Commit.preview(ctx, %{ref: ref, selections: [%{dep: @dep, label: "empty"}]})

    assert {:error, {:selection_fields_unavailable, @dep, ["ORG"]}} =
             Commit.preview(ctx, %{
               ref: ref,
               selections: [%{dep: @dep, label: "work", fields: ["ORG"]}]
             })

    # An explicit empty list names nothing: refused, never "every field".
    assert {:error, {:invalid_argument, _message}} =
             Commit.preview(ctx, %{
               ref: ref,
               selections: [%{dep: @dep, label: "work", fields: []}]
             })

    # A revoked lender is not offered and not accepted.
    :ok = Arca.ProfileStorage.set_status(Sanctum.Context.actor(ctx), lenders.work, "revoked")
    {:ok, plan} = Plan.plan(ctx, %{ref: ref})
    [%{candidates: candidates}] = plan.dependency_needs
    refute Enum.any?(candidates, &(&1.profile_id == lenders.work))

    assert {:error, {:selection_profile_unavailable, @dep, _}} =
             Commit.preview(ctx, %{ref: ref, selections: [%{dep: @dep, label: "work"}]})
  end

  test "a grant keeps the head's selections, and a revoked lender stops lending", %{ctx: ctx} do
    lenders = lenders!(ctx)
    ref = "reagent:local.sel-source"

    {{:ok, %{profile_id: profile_id}}, _} =
      walk!(ctx, ref, %{selections: [%{dep: @dep, label: "default"}]})

    own = entry!(ctx, "own key", %{"token" => "t"})

    assert {:ok, %{revision: 2}} =
             Commit.grant(ctx, %{
               profile_id: profile_id,
               bindings: [%{need: "@ingress", entry_id: own.id}],
               expected_consent_revision: 1
             })

    home_id = lenders.home_entry.id
    assert %{entry_id: ^home_id} = edge_vault(ctx, ref)

    # Revoking the lender's profile is one act that reaches every source
    # selecting it: the edge stays a selection no run can unseal.
    :ok = Arca.ProfileStorage.set_status(Sanctum.Context.actor(ctx), lenders.default, "revoked")
    assert %{via: %{label: "default"}} = edge_vault(ctx, ref)
  end

  describe "a run's consent that cannot be read" do
    # The source borrows the dependency's "default" key; each case breaks
    # what the run reads, and reads the refusal as a person reads it.
    setup %{ctx: ctx} do
      lenders = lenders!(ctx)
      ref = "reagent:local.sel-source"

      {{:ok, %{profile_id: borrower}}, _} =
        walk!(ctx, ref, %{selections: [%{dep: @dep, label: "default"}]})

      {:ok, %{id: consent_id}} = Sanctum.Consent.head_consent(ctx, borrower)
      home_id = lenders.home_entry.id
      assert %{entry_id: ^home_id} = edge_vault(ctx, ref)

      {:ok, lender: lenders.default, ref: ref, borrower: borrower, consent_id: consent_id}
    end

    test "a lender that does not decode refuses the run in its own sentence, and an absent " <>
           "one leaves the selection",
         %{ctx: ctx, lender: lender, ref: ref} do
      damaged =
        "A profile that lends a key here is damaged and cannot lend its key — " <>
          "revoke profile #{lender} and grant it again."

      set_profile!(ctx, lender, kind: "sideways")
      assert {:error, {:lender_corrupt, @dep, ^lender} = reason} = run(ctx, ref)
      assert %Prima.Refusal{class: :corrupt, message: ^damaged} = Grimoire.Error.classify(reason)

      set_profile!(ctx, lender, kind: "owner", label: "elsewhere")
      assert %{via: %{label: "default"}} = edge_vault(ctx, ref)

      set_profile!(ctx, lender, label: "default")
      :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, lender, scope: "sideways")
      assert {:error, {:lender_corrupt, @dep, ^lender} = reason} = run(ctx, ref)
      assert %Prima.Refusal{class: :corrupt, message: ^damaged} = Grimoire.Error.classify(reason)

      :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, lender, scope: "versionless")

      {:ok, %{head_consent_id: head}} =
        Arca.ProfileStorage.get(Sanctum.Context.actor(ctx), lender)

      set_profile!(ctx, lender, head_consent_id: nil)
      assert %{via: %{label: "default"}} = edge_vault(ctx, ref)

      set_profile!(ctx, lender, head_consent_id: head)
      assert %{entry_id: _} = edge_vault(ctx, ref)
    end

    # The store stops answering once the run's own head is read, so only
    # the lender's read meets the outage.
    @tag :capture_log
    test "a lender the store cannot answer refuses the run in its own sentence",
         %{ctx: ctx, ref: ref, consent_id: consent_id} do
      unreadable = "A profile that lends a key here cannot be read right now — try again."

      for table <- ~w(profiles consents) do
        away_after_head!(table, consent_id)
        assert {:error, {:lender_unavailable, @dep} = reason} = run(ctx, ref), table

        assert %Prima.Refusal{class: :unavailable, message: ^unreadable} =
                 Grimoire.Error.classify(reason)

        Arca.Repo.query!("ALTER TABLE #{table}_unavailable RENAME TO #{table}")
      end
    end

    @tag :capture_log
    test "the run's own head, damaged or unanswered, refuses the run in its own sentence",
         %{ctx: ctx, ref: ref, borrower: borrower} do
      damaged =
        "This app's consent is damaged and cannot be used — " <>
          "revoke profile #{borrower} and grant it again."

      :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, borrower, scope: "sideways")
      assert {:error, {:head_corrupt, ^borrower} = reason} = run(ctx, ref)
      assert %Prima.Refusal{class: :corrupt, message: ^damaged} = Grimoire.Error.classify(reason)

      :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, borrower, scope: "versionless")
      Arca.Repo.query!("ALTER TABLE consents RENAME TO consents_unavailable")
      assert {:error, {:head_unavailable, ^borrower} = reason} = run(ctx, ref)

      assert %Prima.Refusal{
               class: :unavailable,
               message: "This app's consent cannot be read right now — try again."
             } = Grimoire.Error.classify(reason)
    end
  end

  # The authority a run of `ref` is admitted under, as `Crucible` loads it.
  defp run(ctx, ref), do: Crucible.authority_for(ctx, :default, ref)

  defp set_profile!(ctx, id, changes) do
    {1, _} =
      Arca.Repo.update_all(
        Ecto.Query.from(p in Arca.Schemas.Profile,
          where: p.athanor_id == ^ctx.athanor_id and p.id == ^id
        ),
        set: changes
      )
  end

  # `table` stops answering once the head `consent_id` names is read whole
  # (its `consent_vault_refs`, the last read of that head), before what
  # follows it.
  defp away_after_head!(table, consent_id) do
    test = self()
    handler = "selection-flow-away-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == test and meta[:source] == "consent_vault_refs" and
               consent_id in (meta[:params] || []) do
            :telemetry.detach(handler)
            Arca.Repo.query!("ALTER TABLE #{table} RENAME TO #{table}_unavailable")
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "a lender's entry revoked or rebound after the borrower's consent refuses the borrower's use",
       %{ctx: ctx} do
    actor = Sanctum.Context.actor(ctx)

    # Two disclosed keys, so a borrower's read reaches the material until
    # the entry under it changes: one lent as "default", one as "work".
    [home, work] =
      for name <- ["home key", "work key"] do
        {:ok, view} =
          Sanctum.TestContext.create_vault(ctx, %{
            name: name,
            kind: "api_key",
            provider_hint: "example.com",
            fields: %{"KEY" => "k-#{name}", "ORG" => "o-#{name}"},
            destination: %{"hosts" => ["api.example.com"]},
            disclose: true
          })

        view
      end

    {{:ok, %{profile_id: home_lender}}, _} =
      walk!(ctx, @dep, %{bindings: [%{need: "api_key", entry_id: home.id}]})

    {{:ok, %{profile_id: work_lender}}, _} =
      walk!(ctx, @dep, %{label: "work", bindings: [%{need: "api_key", entry_id: work.id}]})

    rebound_ref = "reagent:local.sel-source"
    revoked_ref = "reagent:local.sel-source-two"

    {{:ok, %{profile_id: rebound_borrower}}, _} =
      walk!(ctx, rebound_ref, %{selections: [%{dep: @dep, label: "default"}]})

    {{:ok, %{profile_id: revoked_borrower}}, _} =
      walk!(ctx, revoked_ref, %{selections: [%{dep: @dep, label: "work"}]})

    rebound_vault = edge_vault(ctx, rebound_ref)
    revoked_vault = edge_vault(ctx, revoked_ref)
    rebound_use = edge_use(ctx, rebound_ref)
    revoked_use = edge_use(ctx, revoked_ref)

    assert {:ok, %{"KEY" => "k-home key"}} =
             Sanctum.VaultReader.fetch(ctx, rebound_vault, rebound_use)

    assert {:ok, %{"KEY" => "k-work key"}} =
             Sanctum.VaultReader.fetch(ctx, revoked_vault, revoked_use)

    # Rebound: the lender's head is blocked and the borrower's is not, yet
    # the borrower's use refuses at both checks: the read under what it
    # loaded before, and the selection resolved after.
    assert {:ok, %{affected: [^home_lender]}} =
             Sanctum.Vault.rebind(ctx, %{
               id: home.id,
               destination: %{"hosts" => ["api.example.com"], "paths" => ["/v1/"]}
             })

    assert {:error, :binding_mismatch} =
             Sanctum.VaultReader.fetch(ctx, rebound_vault, rebound_use)

    assert %{via: %{label: "default"}} = edge_vault(ctx, rebound_ref)

    # Revoked: both heads stand, the selection still resolves to the entry,
    # and its material is read by no one.
    assert {:ok, %{affected: [^work_lender]}} = Sanctum.Vault.revoke(ctx, work.id)

    assert {:error, {:entry_unavailable, "revoked"}} =
             Sanctum.VaultReader.fetch(ctx, revoked_vault, revoked_use)

    work_id = work.id
    assert %{entry_id: ^work_id} = fresh = edge_vault(ctx, revoked_ref)

    assert {:error, {:entry_unavailable, "revoked"}} =
             Sanctum.VaultReader.fetch(ctx, fresh, revoked_use)

    # Nothing about either was persisted on the borrowers.
    for borrower <- [rebound_borrower, revoked_borrower] do
      assert {:ok, %{status: "active"}} = Arca.ProfileStorage.get(actor, borrower)
    end
  end

  test "the profile tool decodes selections on the wire", %{ctx: ctx} do
    _lenders = lenders!(ctx)
    ref = "reagent:local.sel-source"
    {:ok, plan} = Profile.handle(ctx, %{"action" => "plan", "ref" => ref})

    decisions = %{
      "ref" => ref,
      "selections" => [%{"dep" => @dep, "fields" => ["KEY"]}]
    }

    {:ok, preview} =
      Profile.handle(ctx, %{"action" => "preview", "decisions" => decisions})

    {:ok, %{status: "committed"}} =
      Profile.handle(ctx, %{
        "action" => "commit",
        "decisions" => decisions,
        "plan_token" => plan.plan_token,
        "proof" => preview.proof,
        "commit_digest" => preview.commit_digest,
        "expected_consent_revision" => plan.expected_consent_revision
      })

    assert %{projection: %{fields: ["KEY"]}} = edge_vault(ctx, ref)

    {:ok, with_from} =
      Profile.handle(ctx, %{
        "action" => "preview",
        "decisions" => %{
          "ref" => ref,
          "selections" => [%{"from" => ref, "dep" => @dep, "label" => "default"}]
        }
      })

    assert is_binary(with_from.commit_digest)

    assert {:error, msg} =
             Profile.handle(ctx, %{
               "action" => "preview",
               "decisions" => %{
                 "ref" => ref,
                 "selections" => [%{"dep" => @dep, "label" => "nope"}]
               }
             })

    assert msg =~ "selection_profile_unavailable"
  end

  test "a dependency's need offers its own choice, and a selection naming an entry binds " <>
         "the edge itself, its lifetime on its row",
       %{ctx: ctx} do
    lenders = lenders!(ctx)
    ref = "reagent:local.sel-source"

    {:ok, plan} = Profile.handle(ctx, %{"action" => "plan", "ref" => ref})
    [%{needs: [need]}] = plan.dependency_needs

    # Both keys are of the need's provider and disclosed; the first of the
    # provider is the athanor's default, which the plan suggests.
    assert Enum.sort(Enum.map(need.candidates, & &1.entry_id)) ==
             Enum.sort([lenders.home_entry.id, lenders.work_entry.id])

    assert need.suggested == %{entry_id: lenders.home_entry.id}
    assert need.source == "own"
    refute need.choice_required

    decisions = %{
      "ref" => ref,
      "selections" => [
        %{
          "dep" => @dep,
          "entry_id" => lenders.work_entry.id,
          "fields" => ["KEY"],
          "lifetime" => %{"kind" => "once"}
        }
      ]
    }

    {:ok, preview} = Profile.handle(ctx, %{"action" => "preview", "decisions" => decisions})

    assert [%{"values" => values}] = Enum.filter(preview.rows, &(&1["kind"] == "credential"))
    assert values["lifetime"] == %{"kind" => "once", "until" => nil}
    assert values["suggested"] == false
    refute Map.has_key?(values, "label")

    {:ok, %{status: "committed", profile_id: profile_id}} =
      Profile.handle(ctx, %{
        "action" => "commit",
        "decisions" => decisions,
        "plan_token" => plan.plan_token,
        "proof" => preview.proof,
        "commit_digest" => preview.commit_digest,
        "expected_consent_revision" => plan.expected_consent_revision
      })

    work_id = lenders.work_entry.id

    {:ok, head} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile_id)

    assert [
             %{
               binding_key: "reagent:local.sel-source|reagent:local.sel-dep|default",
               vault_entry_id: ^work_id,
               via_label: nil,
               lifetime_kind: "once"
             }
           ] = head.vault_refs

    # The edge binds the entry itself, under the need's projection as the
    # selection narrowed it: no lender stands behind it.
    assert %{entry_id: ^work_id, projection: %{fields: ["KEY"]}} = vault = edge_vault(ctx, ref)
    refute Map.has_key?(vault, :lender)
  end

  test "a dependency's edge binds named accounts beside its default entry, each a row of its " <>
         "own, and the loaded edge answers a call naming one",
       %{ctx: ctx} do
    home = entry!(ctx, "home key", %{"KEY" => "k-home", "ORG" => "o-home"})
    work = entry!(ctx, "work key", %{"KEY" => "k-work", "ORG" => "o-work"})
    ref = "reagent:local.sel-source"

    {{:ok, %{profile_id: profile_id}}, preview} =
      walk!(ctx, ref, %{
        selections: [
          %{dep: @dep, entry_id: home.id},
          %{dep: @dep, entry_id: work.id, name: "Work", lifetime: %{kind: "once"}}
        ]
      })

    assert [nil, "Work"] =
             preview.rows
             |> Enum.filter(&(&1["kind"] == "credential"))
             |> Enum.map(& &1["values"]["connection"])
             |> Enum.sort_by(&to_string/1)

    {home_id, work_id} = {home.id, work.id}
    {:ok, head} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile_id)

    assert [
             %{
               binding_key: "reagent:local.sel-source|reagent:local.sel-dep|default",
               vault_entry_id: ^home_id,
               lifetime_kind: "standing"
             },
             %{
               binding_key: "reagent:local.sel-source|reagent:local.sel-dep|name:Work",
               vault_entry_id: ^work_id,
               lifetime_kind: "once"
             }
           ] = Enum.sort_by(head.vault_refs, & &1.binding_key)

    # The loaded edge holds the named map beside its default, and a call
    # naming an account gets that account, naming none the default, and
    # naming one the edge lacks nothing.
    {:ok, authority} = Crucible.authority_for(ctx, :default, ref)
    {:ok, edge} = Blob.lookup_edge(authority.policy, ref, @dep, "")

    assert %{entry_id: ^home_id, named: %{"Work" => %{entry_id: ^work_id}}} = edge.vault

    assert {:ok, %{entry_id: ^work_id, binding_key: work_key}} = Blob.vault_for(edge, "Work")
    assert work_key == "reagent:local.sel-source|reagent:local.sel-dep|name:Work"
    assert {:ok, %{entry_id: ^home_id} = default} = Blob.vault_for(edge, nil)
    refute Map.has_key?(default, :named)
    assert Blob.vault_for(edge, "Home") == {:error, :connection_not_granted}

    assert {:child, child} =
             Transition.step(
               authority,
               :call,
               Fixtures.invoke(@dep, need: nil, declared_needs: [], connection: "Work")
             )

    assert child.resources.vault.entry_id == work_id
  end

  test "two roles on one catalyst carry two keys under one root", %{ctx: ctx} do
    lenders = lenders!(ctx)
    tree!(ctx)

    {{:ok, _}, preview} =
      walk!(ctx, @root, %{
        selections: [
          %{from: @role_a, dep: @dep, label: "default"},
          %{from: @role_b, dep: @dep, label: "work"}
        ]
      })

    {:ok, same_from_a} =
      Commit.preview(ctx, %{
        ref: @root,
        selections: [%{from: @role_a, dep: @dep, label: "default"}]
      })

    {:ok, same_from_b} =
      Commit.preview(ctx, %{
        ref: @root,
        selections: [%{from: @role_b, dep: @dep, label: "default"}]
      })

    assert preview.commit_digest != same_from_a.commit_digest
    assert same_from_a.commit_digest != same_from_b.commit_digest

    {:ok, plan} = Plan.plan(ctx, %{ref: @root})

    assert [
             %{from: @role_a, dep: @dep},
             %{from: @role_b, dep: @dep}
           ] = Enum.sort_by(plan.dependency_needs, & &1.from)

    home_id = lenders.home_entry.id
    work_id = lenders.work_entry.id

    assert %{entry_id: ^home_id} = root_edge_vault(ctx, @role_a)
    assert %{entry_id: ^work_id} = root_edge_vault(ctx, @role_b)

    {:ok, authority} = Crucible.authority_for(ctx, :default, @root)

    {:child, via_a} =
      authority
      |> Transition.step(:call, Fixtures.invoke(@role_a, need: nil, declared_needs: []))
      |> then(fn {:child, child} ->
        Transition.step(child, :call, Fixtures.invoke(@dep, need: nil, declared_needs: []))
      end)

    {:child, via_b} =
      authority
      |> Transition.step(:call, Fixtures.invoke(@role_b, need: nil, declared_needs: []))
      |> then(fn {:child, child} ->
        Transition.step(child, :call, Fixtures.invoke(@dep, need: nil, declared_needs: []))
      end)

    assert via_a.resources.vault.entry_id == home_id
    assert via_b.resources.vault.entry_id == work_id

    :ok = Arca.ProfileStorage.set_status(Sanctum.Context.actor(ctx), lenders.work, "revoked")
    assert %{entry_id: ^home_id} = root_edge_vault(ctx, @role_a)
    assert %{via: %{label: "work"}} = root_edge_vault(ctx, @role_b)
  end

  test "one key may ride two edges under two projections", %{ctx: ctx} do
    lenders = lenders!(ctx)
    tree!(ctx)

    {{:ok, _}, _} =
      walk!(ctx, @root, %{
        selections: [
          %{from: @role_a, dep: @dep, label: "default", fields: ["KEY"]},
          %{from: @role_b, dep: @dep, label: "default", fields: ["KEY", "ORG"]}
        ]
      })

    home_id = lenders.home_entry.id

    assert %{entry_id: ^home_id, projection: %{fields: ["KEY"]}} =
             root_edge_vault(ctx, @role_a)

    assert %{entry_id: ^home_id, projection: %{fields: ["KEY", "ORG"]}} =
             root_edge_vault(ctx, @role_b)
  end

  test "one entry lent on two edges of one node is two rows, one per edge", %{ctx: ctx} do
    lenders = lenders!(ctx)
    dep_two = "reagent:local.sel-dep-two"

    publish!(ctx, "sel-dep-two", %{
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:example.com",
          "reason" => "to call the example API too",
          "required" => true,
          "fields" => ["KEY", "ORG"]
        }
      }
    })

    {{:ok, _}, _} =
      walk!(ctx, dep_two, %{bindings: [%{need: "api_key", entry_id: lenders.home_entry.id}]})

    publish!(ctx, "sel-source-both", %{
      "dependencies" => %{"static" => [%{"ref" => @dep}, %{"ref" => dep_two}]}
    })

    # The same key, lent by one node into two dependencies under two
    # projections: each edge is its own row, neither hidden nor refused.
    {{:ok, _}, preview} =
      walk!(ctx, "reagent:local.sel-source-both", %{
        selections: [
          %{dep: @dep, label: "default", fields: ["KEY"]},
          %{dep: dep_two, label: "default"}
        ]
      })

    credentials =
      for %{"kind" => "credential", "node" => "reagent:local.sel-source-both"} = row <-
            preview.rows,
          do: row["values"]

    assert [
             %{"name" => "home key", "edge" => @dep, "fields" => ["KEY"]},
             %{"name" => "home key", "edge" => ^dep_two, "fields" => ["KEY", "ORG"]}
           ] = Enum.sort_by(credentials, & &1["edge"])
  end

  test "a bound credential riding a dependency edge is the row of that edge", %{ctx: ctx} do
    # A closure with a cycle: the source depends on a component that
    # depends on the source back, so the edge into the source from it
    # carries the source's own bound key.
    source = "reagent:local.sel-cycle-source"
    back = "reagent:local.sel-cycle-back"
    publish!(ctx, "sel-cycle-source", %{"dependencies" => %{"static" => [%{"ref" => back}]}})
    publish!(ctx, "sel-cycle-back", %{"dependencies" => %{"static" => [%{"ref" => source}]}})
    key = entry!(ctx, "cycle key", %{"KEY" => "k-cycle"})

    {:ok, preview} =
      Commit.preview(ctx, %{ref: source, bindings: [%{need: "@ingress", entry_id: key.id}]})

    credentials =
      for %{"kind" => "credential", "values" => values} = row <- preview.rows,
          do: {row["node"], values["edge"], values["name"]}

    assert Enum.sort(credentials) == [
             {back, source, "cycle key"},
             {source, "@ingress", "cycle key"}
           ]
  end

  defp tree!(ctx) do
    publish!(ctx, "sel-role-a", %{"dependencies" => %{"static" => [%{"ref" => @dep}]}})
    publish!(ctx, "sel-role-b", %{"dependencies" => %{"static" => [%{"ref" => @dep}]}})

    publish!(ctx, "sel-root", %{
      "dependencies" => %{"static" => [%{"ref" => @role_a}, %{"ref" => @role_b}]}
    })
  end

  defp root_edge_vault(ctx, from) do
    {:ok, authority} = Crucible.authority_for(ctx, :default, @root)
    {:ok, edge} = Blob.lookup_edge(authority.policy, from, @dep, "")
    edge.vault
  end
end
