# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ProviderVaultProfileTest do
  use ExUnit.Case, async: false

  @wasm File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "mcp_vault_profile_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "the whole walk works over the wire shape — string keys end to end", %{ctx: ctx} do
    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: "mcp-walk",
        version: "1.0.0",
        type: "reagent"
      })

    # vault.create over wire args, under the confirmation entering a
    # credential needs (`Sanctum.TestContext.confirming/2`)
    {:ok, %{entry: entry}} =
      Sanctum.TestContext.confirming(
        ctx,
        &Sanctum.Provider.handle("vault", &1, %{
          "action" => "create",
          "name" => "wire-conn",
          "kind" => "api_key",
          "fields" => %{"url" => "https://db.example", "anon_key" => "anon"},
          "destination" => %{"hosts" => ["db.example"]},
          # A manifest declaring no need: the component reads its key.
          "disclose" => true
        })
      )

    {:ok, %{entries: entries}} = Sanctum.Provider.handle("vault", ctx, %{"action" => "list"})
    assert Enum.any?(entries, &(&1.id == entry.id))

    # profile.plan
    {:ok, plan} =
      Sanctum.Provider.handle("profile", ctx, %{
        "action" => "plan",
        "ref" => "reagent:local.mcp-walk"
      })

    assert plan.expected_consent_revision == 0

    decisions = %{
      "ref" => "reagent:local.mcp-walk",
      "bindings" => [
        %{"need" => "@ingress", "entry_id" => entry.id, "fields" => ["url", "anon_key"]}
      ]
    }

    {:ok, preview} =
      Sanctum.Provider.handle("profile", ctx, %{"action" => "preview", "decisions" => decisions})

    {:ok, committed} =
      Sanctum.Provider.handle("profile", ctx, %{
        "action" => "commit",
        "decisions" => decisions,
        "plan_token" => plan.plan_token,
        "proof" => preview.proof,
        "commit_digest" => preview.commit_digest,
        "expected_consent_revision" => 0
      })

    assert committed.status == "committed"
    assert committed.revision == 1

    # profile.list shows the head revision
    {:ok, %{profiles: [profile]}} =
      Sanctum.Provider.handle("profile", ctx, %{
        "action" => "list",
        "ref" => "reagent:local.mcp-walk"
      })

    assert profile.head_revision == 1

    # profile.revoke closes it out
    {:ok, %{status: "revoked"}} =
      Sanctum.Provider.handle("profile", ctx, %{
        "action" => "revoke",
        "profile_id" => committed.profile_id
      })

    {:ok, reloaded} = Arca.ProfileStorage.get(Sanctum.Context.actor(ctx), committed.profile_id)
    assert reloaded.status == "revoked"
  end

  test "conflicts cross the boundary as a typed consent signal", %{ctx: ctx} do
    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: "mcp-conflict",
        version: "1.0.0",
        type: "reagent"
      })

    decisions = %{"ref" => "reagent:local.mcp-conflict"}

    {:ok, plan} =
      Sanctum.Provider.handle("profile", ctx, %{
        "action" => "plan",
        "ref" => "reagent:local.mcp-conflict"
      })

    {:ok, preview} =
      Sanctum.Provider.handle("profile", ctx, %{"action" => "preview", "decisions" => decisions})

    # Typed to the boundary: the wire router promotes this to a protocol
    # error (-33503 + error.data via Prima.ConsentSignal).
    assert {:error, {:consent_conflict, payload}} =
             Sanctum.Provider.handle("profile", ctx, %{
               "action" => "commit",
               "decisions" => decisions,
               "plan_token" => plan.plan_token,
               "proof" => preview.proof,
               "commit_digest" => preview.commit_digest,
               "expected_consent_revision" => 7
             })

    assert %{cause: :stale_plan, actual_revision: 0} = payload
    assert Prima.ConsentSignal.signal?({:consent_conflict, payload})
  end

  test "list answers the athanor's default per provider beside its entries, never material",
       %{ctx: ctx} do
    create = fn name ->
      {:ok, %{entry: entry}} =
        Sanctum.TestContext.confirming(
          ctx,
          &Sanctum.Provider.handle("vault", &1, %{
            "action" => "create",
            "name" => name,
            "kind" => "api_key",
            "provider_hint" => "openai.com",
            "fields" => %{"OPENAI_API_KEY" => "sk-material-#{name}"},
            "destination" => %{"hosts" => ["api.openai.com"]}
          })
        )

      entry
    end

    first = create.("first-key")
    second = create.("second-key")

    assert {:ok, %{entries: entries, defaults: defaults} = answer} =
             Sanctum.Provider.handle("vault", ctx, %{"action" => "list"})

    assert Enum.map([first, second], & &1.id) -- Enum.map(entries, & &1.id) == []
    assert defaults == %{"openai.com" => %{vault_entry_id: first.id}}

    # On the wire the defaults are an object keyed by provider hint, and
    # name an entry by id alone: no material, and no field.
    wire = Jason.encode!(answer)
    assert Jason.decode!(wire)["defaults"] == %{"openai.com" => %{"vault_entry_id" => first.id}}
    refute wire =~ "sk-material"
    refute Jason.encode!(defaults) =~ "OPENAI_API_KEY"
  end

  test "set_default makes an entry a provider's default over the wire", %{ctx: ctx} do
    create = fn name, hint ->
      {:ok, %{entry: entry}} =
        Sanctum.TestContext.confirming(
          ctx,
          &Sanctum.Provider.handle("vault", &1, %{
            "action" => "create",
            "name" => name,
            "kind" => "api_key",
            "provider_hint" => hint,
            "fields" => %{"OPENAI_API_KEY" => "sk-material-#{name}"},
            "destination" => %{"hosts" => ["api.openai.com"]}
          })
        )

      entry
    end

    _first = create.("first-default", "openai.com")
    second = create.("second-default", "openai.com")
    other = create.("other-provider", "anthropic.com")

    assert {:ok, %{status: "default_set", default: default}} =
             Sanctum.Provider.handle("vault", ctx, %{
               "action" => "set_default",
               "provider_hint" => "openai.com",
               "entry_id" => second.id
             })

    assert default == %{provider_hint: "openai.com", vault_entry_id: second.id}

    {:ok, %{defaults: defaults}} = Sanctum.Provider.handle("vault", ctx, %{"action" => "list"})
    assert defaults["openai.com"] == %{vault_entry_id: second.id}

    assert {:error, "provider_mismatch: " <> _} =
             Sanctum.Provider.handle("vault", ctx, %{
               "action" => "set_default",
               "provider_hint" => "openai.com",
               "entry_id" => other.id
             })

    assert {:error, {:invalid_argument, _}} =
             Sanctum.Provider.handle("vault", ctx, %{
               "action" => "set_default",
               "provider_hint" => "openai.com"
             })

    # The declaration names what the handler takes, and nothing it ignores.
    %{args: args} =
      Enum.find(Sanctum.Providers.Vault.definition().operations, &(&1.action == "set_default"))

    assert Enum.map(args, & &1.name) |> Enum.sort() ==
             ["entry_id", "instance_entry_id", "provider_hint"]
  end

  test "the profile tool decodes the extended decisions, and refuses what it cannot keep",
       %{ctx: ctx} do
    # A person of this home: an instance entry is offered to people.
    {ctx, _user} = Sanctum.TestContext.person!(ctx)

    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: "mcp-keyed",
        version: "1.0.0",
        type: "reagent",
        manifest:
          Jason.encode!(%{
            "name" => "mcp-keyed",
            "version" => "1.0.0",
            "type" => "reagent",
            "needs" => %{
              "api_key" => %{
                "type" => "api_key:openai.com",
                "reason" => "to call the model",
                "fields" => ["OPENAI_API_KEY"],
                "attach" => %{
                  "in" => "header",
                  "name" => "Authorization",
                  "template" => "Bearer {value}"
                }
              }
            }
          })
      })

    entries =
      for name <- ["wire-a", "wire-b"] do
        {:ok, %{entry: entry}} =
          Sanctum.TestContext.confirming(
            ctx,
            &Sanctum.Provider.handle("vault", &1, %{
              "action" => "create",
              "name" => name,
              "kind" => "api_key",
              "provider_hint" => "openai.com",
              "fields" => %{"OPENAI_API_KEY" => "sk-#{name}"},
              "destination" => %{"hosts" => ["api.openai.com"]}
            })
          )

        entry
      end

    [a, b] = entries

    preview = fn bindings ->
      Sanctum.Provider.handle("profile", ctx, %{
        "action" => "preview",
        "decisions" => %{"ref" => "reagent:local.mcp-keyed", "bindings" => bindings}
      })
    end

    assert {:ok, %{rows: rows}} =
             preview.([
               %{"need" => "api_key", "entry_id" => a.id},
               %{
                 "need" => "api_key",
                 "entry_id" => b.id,
                 "name" => "Second",
                 "lifetime" => %{"kind" => "once"},
                 "renew" => true
               }
             ])

    assert [%{"values" => %{"connection" => "Second", "lifetime" => %{"kind" => "once"}}}] =
             Enum.filter(rows, &(&1["kind"] == "credential" and &1["values"]["connection"]))

    # A lifetime member the commit does not know is refused, never dropped;
    # and each refusal names the need in its own words.
    assert {:error, why} =
             preview.([
               %{
                 "need" => "api_key",
                 "entry_id" => a.id,
                 "lifetime" => %{"kind" => "once", "x" => 1}
               }
             ])

    assert why =~ "The binding for api_key"

    assert {:error, "not_offered: " <> why} =
             preview.([%{"need" => "api_key", "instance_entry_id" => "ine_missing"}])

    assert why =~ "api_key"
  end

  test "the profile tool decodes a selection's account name, refuses one the binding key " <>
         "cannot carry, and publish refuses an edge carrying named accounts",
       %{ctx: ctx} do
    keyed =
      Jason.encode!(%{
        "name" => "mcp-named-dep",
        "version" => "1.0.0",
        "type" => "reagent",
        "needs" => %{
          "api_key" => %{
            "type" => "api_key:openai.com",
            "reason" => "to call the model",
            "fields" => ["OPENAI_API_KEY"],
            "attach" => %{
              "in" => "header",
              "name" => "Authorization",
              "template" => "Bearer {value}"
            }
          }
        }
      })

    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: "mcp-named-dep",
        version: "1.0.0",
        type: "reagent",
        manifest: keyed
      })

    dep = "reagent:local.mcp-named-dep"

    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: "mcp-named-app",
        version: "1.0.0",
        type: "reagent",
        manifest:
          Jason.encode!(%{
            "name" => "mcp-named-app",
            "version" => "1.0.0",
            "type" => "reagent",
            "dependencies" => %{"static" => [%{"ref" => dep}]}
          })
      })

    ref = "reagent:local.mcp-named-app"

    [default, work] =
      for name <- ["named-default", "named-work"] do
        {:ok, %{entry: entry}} =
          Sanctum.TestContext.confirming(
            ctx,
            &Sanctum.Provider.handle("vault", &1, %{
              "action" => "create",
              "name" => name,
              "kind" => "api_key",
              "provider_hint" => "openai.com",
              "fields" => %{"OPENAI_API_KEY" => "sk-#{name}"},
              "destination" => %{"hosts" => ["api.openai.com"]}
            })
          )

        entry
      end

    decisions = fn name ->
      %{
        "ref" => ref,
        "selections" => [
          %{"dep" => dep, "entry_id" => default.id},
          %{
            "dep" => dep,
            "entry_id" => work.id,
            "name" => name,
            "lifetime" => %{"kind" => "once"}
          }
        ]
      }
    end

    {:ok, plan} = Sanctum.Provider.handle("profile", ctx, %{"action" => "plan", "ref" => ref})

    {:ok, preview} =
      Sanctum.Provider.handle("profile", ctx, %{
        "action" => "preview",
        "decisions" => decisions.("Work")
      })

    assert [%{"values" => %{"connection" => "Work", "lifetime" => %{"kind" => "once"}}}] =
             Enum.filter(
               preview.rows,
               &(&1["kind"] == "credential" and &1["values"]["connection"])
             )

    assert {:error, why} =
             Sanctum.Provider.handle("profile", ctx, %{
               "action" => "preview",
               "decisions" => decisions.("has|pipe")
             })

    assert why ==
             "The selection of #{dep} names an account that is not 1 to 128 bytes of text " <>
               "without a | or a control character"

    {:ok, %{status: "committed", profile_id: profile_id}} =
      Sanctum.Provider.handle("profile", ctx, %{
        "action" => "commit",
        "decisions" => decisions.("Work"),
        "plan_token" => plan.plan_token,
        "proof" => preview.proof,
        "commit_digest" => preview.commit_digest,
        "expected_consent_revision" => plan.expected_consent_revision
      })

    {:ok, head} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile_id)

    assert Enum.sort(Enum.map(head.vault_refs, & &1.binding_key)) == [
             "#{ref}|#{dep}|default",
             "#{ref}|#{dep}|name:Work"
           ]

    # A public profile's callers are anonymous: an edge it keeps may not
    # carry named accounts, and the publish says so.
    assert {:error, why} =
             Sanctum.Provider.handle("profile", ctx, %{
               "action" => "publish",
               "profile_id" => profile_id,
               "need_ids" => [dep]
             })

    assert why ==
             "The public profile cannot keep #{dep}: it binds named accounts beside its " <>
               "default, which a public profile cannot carry"
  end

  # The entry a commit binds, revoked once the commit has read it and
  # before its revision locks it: run at the commit's first read of an
  # athanor's entry, once, on the connection the read has just released.
  def revoke_after_read(_event, _measurements, meta, %{test: test, ctx: ctx, entry_id: id}) do
    if self() == test and meta[:source] == "vault_entries" and Process.get(:revoked) == nil do
      revoked =
        Task.async(fn ->
          Arca.VaultStorage.set_status(Sanctum.Context.actor(ctx), id, "revoked")
        end)
        |> Task.await(30_000)

      Process.put(:revoked, revoked)
    end
  end

  test "a commit whose entry is revoked after its read is refused by the revision's lock, " <>
         "in the refusal's own words",
       %{ctx: ctx} do
    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: "mcp-locked",
        version: "1.0.0",
        type: "reagent"
      })

    {:ok, %{entry: entry}} =
      Sanctum.TestContext.confirming(
        ctx,
        &Sanctum.Provider.handle("vault", &1, %{
          "action" => "create",
          "name" => "locked-conn",
          "kind" => "api_key",
          "fields" => %{"url" => "https://db.example", "anon_key" => "anon"},
          "destination" => %{"hosts" => ["db.example"]},
          # A manifest declaring no need: the component reads its key.
          "disclose" => true
        })
      )

    {:ok, plan} =
      Sanctum.Provider.handle("profile", ctx, %{
        "action" => "plan",
        "ref" => "reagent:local.mcp-locked"
      })

    decisions = %{
      "ref" => "reagent:local.mcp-locked",
      "bindings" => [%{"need" => "@ingress", "entry_id" => entry.id}]
    }

    {:ok, preview} =
      Sanctum.Provider.handle("profile", ctx, %{"action" => "preview", "decisions" => decisions})

    handler = {__MODULE__, :revoke_after_read, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(handler, [:arca, :repo, :query], &__MODULE__.revoke_after_read/4, %{
        test: self(),
        ctx: ctx,
        entry_id: entry.id
      })

    on_exit(fn -> :telemetry.detach(handler) end)

    result =
      Sanctum.Provider.handle("profile", ctx, %{
        "action" => "commit",
        "decisions" => decisions,
        "plan_token" => plan.plan_token,
        "proof" => preview.proof,
        "commit_digest" => preview.commit_digest,
        "expected_consent_revision" => 0
      })

    :telemetry.detach(handler)
    assert Process.get(:revoked) == :ok

    # The store's refusal names no entry; the tool says what it means.
    assert result ==
             {:error, ~s(entry_unavailable: an entry this consent binds is now "revoked")}

    assert {:ok, %{profiles: []}} =
             Sanctum.Provider.handle("profile", ctx, %{
               "action" => "list",
               "ref" => "reagent:local.mcp-locked"
             })
  end

  test "the tincture session surface is named in the refusal", %{ctx: ctx} do
    session_ctx = %{ctx | auth_method: :session}

    assert {:error, "consent_class_required:" <> _} =
             Sanctum.Provider.handle("vault", session_ctx, %{"action" => "list"})
  end

  test "a limits decision is refused rather than signed and ignored", %{ctx: ctx} do
    # It rode the commit digest and stopped there: the blob is built from the
    # manifest's caps, so the operator's number was proofed and recorded while
    # the runtime kept the manifest's. Refusing keeps the digest a promise
    # about what actually runs.
    for action <- ["preview", "commit"] do
      assert {:error, "limits are not a consent decision" <> _} =
               Sanctum.Provider.handle("profile", ctx, %{
                 "action" => action,
                 "decisions" => %{
                   "ref" => "reagent:local.mcp-walk",
                   "limits" => %{"timeout" => "1s"}
                 }
               })
    end
  end
end
