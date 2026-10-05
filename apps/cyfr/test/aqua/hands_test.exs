# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.HandsTest do
  # The host's copy of the guest's virtual-tool contract, held to the one
  # fixture the guest's own tests run (`virtual_tools.json` beside
  # `tools.rs`): every virtual call builds the catalyst request the guest
  # builds, and every catalyst request names the virtual actions the
  # guest's guard would judge it as.
  use ExUnit.Case, async: true

  alias Aqua.Hands

  @fixture Path.expand("../support/fixtures/hands_cases.json", __DIR__)

  defp fixture, do: @fixture |> File.read!() |> Jason.decode!()

  test "the shared fixture holds on both directions" do
    cases = fixture()
    assert length(cases) > 20

    for case <- cases do
      canonical =
        case Hands.canonical(case["catalyst"], case["input"]) do
          {:ok, ops} -> Enum.map(ops, &"#{&1.tool}.#{&1.action}")
          {:error, _} -> []
        end

      assert canonical == case["canonical"], "reverse of #{inspect(case["input"])}"

      unless case["reverse_only"] do
        assert {:ok, %{catalyst: catalyst, input: input}} =
                 Hands.child_call(case["tool"], case["action"], case["args"])

        assert catalyst == case["catalyst"], "#{case["tool"]}.#{case["action"]}"
        assert input == case["input"], "#{case["tool"]}.#{case["action"]}"
      end
    end
  end

  test "a canonical operation carries the virtual tool's own args, so a card can run it again" do
    assert {:ok, [%{tool: "files", action: "delete", args: %{"path" => "a.md"}}]} =
             Hands.canonical("catalyst:local.files", %{
               "action" => "delete",
               "path" => "a.md"
             })

    assert {:ok,
            [%{tool: "storage", action: "write", args: %{"key" => "k", "value" => %{"a" => 1}}}]} =
             Hands.canonical("catalyst:local.files:0.5.2", %{
               "action" => "write_text",
               "path" => "data/storage/k.json",
               "content" => ~s({"a": 1})
             })

    assert {:ok, [%{tool: "http", action: "post", args: %{"url" => "http://x", "body" => "b"}}]} =
             Hands.canonical("catalyst:local.http", %{
               "operation" => "fetch",
               "params" => %{"url" => "http://x", "method" => "POST", "body" => "b"}
             })

    # And round-trips through the child call.
    assert {:ok, %{input: %{"action" => "delete", "path" => "data/storage/k.json"}}} =
             Hands.child_call("storage", "delete", %{"key" => "k"})
  end

  test "references are judged at name level, and only a hand's catalyst is a hand" do
    assert Hands.name_level("catalyst:local.files:0.5.2") == "catalyst:local.files"
    assert Hands.name_level("catalyst:local.files") == "catalyst:local.files"
    assert Hands.hand_catalyst?("catalyst:local.files:0.5.2")
    refute Hands.hand_catalyst?("formula:local.other")
    assert {:error, :not_virtual} = Hands.canonical("formula:local.other", %{})
  end

  test "a files call inside the storage boundary is the storage operation" do
    assert {:ok, %{tool: "storage", action: "delete", args: %{"key" => "k"}}} =
             Hands.canonical_files("delete", %{"path" => "data/storage/k.json"})

    assert {:ok, %{tool: "storage", action: "list", args: %{"key" => "notes"}}} =
             Hands.canonical_files("tree", %{"path" => "data/storage/notes"})

    assert {:ok, %{tool: "files", action: "delete"}} =
             Hands.canonical_files("delete", %{"path" => "a.md"})

    assert {:error, :not_a_storage_operation} =
             Hands.canonical_files("grep", %{"path" => "data/storage", "pattern" => "x"})
  end

  test "request_setup.open is auto-only and builds no child call" do
    assert Hands.auto_only?("request_setup", "open")
    refute Hands.auto_only?("files", "read")
    assert {:error, _} = Hands.child_call("request_setup", "open", %{})
  end
end

defmodule Aqua.HandsLaunchAccountsTest do
  # What a turn reads, once, of the accounts its launches may name: each
  # app whose own default profile binds named accounts, with the names,
  # never an entry, its id or a value.
  use ExUnit.Case, async: false

  alias Aqua.Hands
  alias Sanctum.Consent.{Commit, Plan}

  @wasm File.read!(Path.expand("../support/test_wasm/math.wasm", __DIR__))

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path =
      Path.join(System.tmp_dir!(), "hands_accounts_#{System.unique_integer([:positive])}")

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

  defp app!(ctx, name, accounts) do
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

    entry = fn label ->
      {:ok, view} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "#{name} #{label}",
          kind: "api_key",
          provider_hint: "example.com",
          fields: %{"KEY" => "secret-#{name}-#{label}"},
          destination: %{"hosts" => ["api.example.com"]},
          disclose: true
        })

      view
    end

    ref = "reagent:local." <> name

    bindings =
      [%{need: "api_key", entry_id: entry.("default").id}] ++
        Enum.map(accounts, &%{need: "api_key", name: &1, entry_id: entry.(&1).id})

    decisions = %{ref: ref, bindings: bindings}
    {:ok, plan} = Plan.plan(ctx, %{ref: ref})
    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, _} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    ref
  end

  test "each app whose own profile binds named accounts, with the names, by reference", %{
    ctx: ctx
  } do
    mailer = app!(ctx, "hands-mailer", ["Work", "Personal"])
    db = app!(ctx, "hands-db", ["Supabase 2"])
    _plain = app!(ctx, "hands-plain", [])

    assert %{apps: apps, truncated?: false} = Hands.launch_accounts(ctx)
    assert apps == [{db, ["Supabase 2"]}, {mailer, ["Personal", "Work"]}]

    # The names alone: no entry, its id, or what it holds.
    {:ok, entries} = Sanctum.Vault.list(ctx)
    assert length(entries) >= 6
    text = inspect(apps)
    refute text =~ "secret-"

    for entry <- entries, do: refute(text =~ entry.id)

    # The request the turn sends says the same, the default as what
    # omitting the account takes.
    description =
      %{"execution.run" => "ask"}
      |> Aqua.Loop.Request.tool_definitions(accounts: Hands.launch_accounts(ctx))
      |> Enum.find(&(&1["name"] == "execution"))
      |> get_in(["parameters", "properties", "connection", "description"])

    assert description =~ ~s[#{db} ("Supabase 2")]
    assert description =~ ~s[#{mailer} ("Personal", "Work")]
    assert description =~ "omit `connection` for its default account"
    refute description =~ "hands-plain"
    for entry <- entries, do: refute(description =~ entry.id)
  end
end
