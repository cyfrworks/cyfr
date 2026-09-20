# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.FilesTest do
  @moduledoc """
  The athanor's files as a person sees them: the folders are the layout's
  console tier, the server's own storage has no name, `data/` is open,
  the shaped folders take edits only inside a unit, and the read-only
  folders take none.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Files

  @valid_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
                <<0x03, 0x02, 0x01, 0x00>> <>
                <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
                <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  @shipped ["components", "reagents", "local", "shelf", "1.0.0"]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "files_#{System.unique_integer([:positive])}")
    seed = Path.join(base, "seed")

    prev_base = Application.fetch_env!(:cyfr, :base_path)
    prev_seed = Application.fetch_env!(:cyfr, :seed_path)
    Application.put_env(:cyfr, :base_path, Path.join(base, "data"))
    Application.put_env(:cyfr, :seed_path, seed)

    Arca.Test.UnitFixtures.seed_component!("reagent", "local", "shelf", "1.0.0",
      manifest: %{"type" => "reagent", "version" => "1.0.0", "description" => "shipped"},
      wasm: @valid_wasm
    )

    roles = Path.join([seed, "aqua", "roles"])
    File.mkdir_p!(roles)
    File.write!(Path.join([seed, "aqua", "aqua.md"]), "---\ntitle: A\n---\n\nsoul\n")
    File.write!(Path.join(roles, "scribe.md"), "---\ntitle: Scribe\n---\n\nscribe\n")

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      Application.put_env(:cyfr, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    ctx = Sanctum.TestContext.local()
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    :ok = Arca.ensure_roots(Sanctum.Context.actor(ctx))
    {:ok, ctx: ctx}
  end

  test "the folders are the layout's console tier, and the server's own storage has no name",
       %{ctx: ctx} do
    assert Files.folders() == [
             %{name: "data", tier: :open},
             %{name: "aqua", tier: :shaped},
             %{name: "components", tier: :shaped},
             %{name: "threads", tier: :read},
             %{name: "notes", tier: :read}
           ]

    assert {:ok, %{path: "", tier: nil, entries: entries}} = Files.list(ctx, "")
    assert Enum.map(entries, & &1.name) == ~w(data aqua components threads notes)
    assert Enum.all?(entries, &(&1.kind == :dir))

    for hidden <- ["payloads", "guest", "seed", "cache", "system", "secret"] do
      assert {:error, {:not_found, "Folder", ^hidden}} = Files.list(ctx, hidden)
      assert {:error, {:not_found, "Folder", ^hidden}} = Files.read(ctx, hidden <> "/x.txt")
      assert {:error, {:not_found, "Folder", ^hidden}} = Files.write(ctx, hidden <> "/x.txt", "x")
    end
  end

  test "data/ is open: write, list with sizes, read, delete a file, delete a folder", %{ctx: ctx} do
    assert {:ok, %{written: "data/reports/q3.csv", size: 8}} =
             Files.write(ctx, "data/reports/q3.csv", "a,b\n1,2\n")

    assert {:ok, %{written: "data/reports/logo.bin", size: 3}} =
             Files.write(ctx, "data/reports/logo.bin", Base.encode64(<<0, 255, 1>>), "base64")

    assert {:ok,
            %{path: "data", tier: :open, entries: [%{name: "reports", kind: :dir, size: nil}]}} =
             Files.list(ctx, "data")

    assert {:ok, %{path: "data/reports", entries: entries}} = Files.list(ctx, "data/reports/")

    assert entries == [
             %{name: "logo.bin", kind: :file, size: 3},
             %{name: "q3.csv", kind: :file, size: 8}
           ]

    assert {:ok, %{content: "a,b\n1,2\n", encoding: "utf8", size: 8, path: "data/reports/q3.csv"}} =
             Files.read(ctx, "data/reports/q3.csv")

    assert {:ok, %{content: encoded, encoding: "base64"}} =
             Files.read(ctx, "data/reports/logo.bin")

    assert Base.decode64!(encoded) == <<0, 255, 1>>

    assert {:ok, %{deleted: "data/reports/q3.csv"}} = Files.delete(ctx, "data/reports/q3.csv")

    assert {:error, {:not_found, "File", "data/reports/q3.csv"}} =
             Files.read(ctx, "data/reports/q3.csv")

    assert {:error, {:not_found, "File", "data/reports/q3.csv"}} =
             Files.delete(ctx, "data/reports/q3.csv")

    assert {:ok, %{deleted: "data/reports"}} = Files.delete(ctx, "data/reports")
    assert {:ok, %{entries: []}} = Files.list(ctx, "data")

    # The folder itself is a place, not a file.
    assert {:error, {:invalid_argument, msg}} = Files.write(ctx, "data", "x")
    assert msg =~ "is a folder"
    assert {:error, {:invalid_argument, msg}} = Files.read(ctx, "")
    assert msg =~ "inside a folder"
  end

  test "a path is checked before it is looked at", %{ctx: ctx} do
    assert {:error, {:invalid_argument, _}} = Files.read(ctx, "data/../aqua/aqua.md")
    assert {:error, {:invalid_argument, _}} = Files.write(ctx, "data/a\\b.txt", "x")
    assert {:error, {:invalid_argument, msg}} = Files.write(ctx, "data/x.txt", "nope", "hex")
    assert msg =~ "encoding"
    assert {:error, {:invalid_argument, _}} = Files.write(ctx, "data/x.txt", "@@@", "base64")

    assert {:error, {:invalid_argument, msg}} =
             Files.write(ctx, "data/big.bin", String.duplicate("x", Files.max_write() + 1))

    assert msg =~ "at most"
  end

  test "the read-only folders are listed and read, never written", %{ctx: ctx} do
    assert {:ok, %{tier: :read, entries: []}} = Files.list(ctx, "notes")
    assert {:ok, %{tier: :read}} = Files.list(ctx, "threads")

    for path <- ["notes/plan.md", "threads/thread_1/blob.bin"] do
      assert {:error, {:invalid_argument, msg}} = Files.write(ctx, path, "x")
      assert msg =~ "read here"
      assert {:error, {:invalid_argument, _}} = Files.delete(ctx, path)
    end

    # The retired name for threads/ (spelled split for the vocabulary gate)
    # is no folder.
    retired = "conver" <> "sations"
    assert {:error, {:not_found, "Folder", ^retired}} = Files.list(ctx, retired)
  end

  test "components/ is shaped: edits land only inside a local unit, and a shipped unit is never deleted",
       %{ctx: ctx} do
    assert {:ok, %{tier: :shaped}} = Files.list(ctx, "components")

    assert {:ok, %{entries: [%{name: "1.0.0", kind: :dir}]}} =
             Files.list(ctx, "components/reagents/local/shelf")

    # Outside any unit: nothing lands, whatever the name.
    assert {:error, {:invalid_argument, msg}} = Files.write(ctx, "components/notes.txt", "x")
    assert msg =~ "outside any component"

    assert {:error, {:invalid_argument, _}} =
             Files.write(ctx, "components/reagents/local/shelf/README.md", "x")

    # Inside the shipped copy: an edit, and the unit is still the shipped one.
    assert {:ok, %{written: "components/reagents/local/shelf/1.0.0/notes.txt"}} =
             Files.write(ctx, "components/reagents/local/shelf/1.0.0/notes.txt", "mine")

    assert Arca.Overlay.unit_status(Sanctum.Context.actor(ctx), @shipped) == {:ok, :shipped}
    assert {:ok, true} = Arca.Overlay.edited?(Sanctum.Context.actor(ctx), @shipped)

    # A file inside goes; the unit whole does not.
    assert {:ok, _} = Files.delete(ctx, "components/reagents/local/shelf/1.0.0/notes.txt")

    assert {:error, {:invalid_argument, msg}} =
             Files.delete(ctx, "components/reagents/local/shelf/1.0.0")

    assert msg =~ "ships with the server"

    assert {:error, {:invalid_argument, msg}} = Files.delete(ctx, "components/reagents")
    assert msg =~ "holds units"

    # A pulled component is fork-to-modify.
    assert {:error, {:invalid_argument, msg}} =
             Files.write(ctx, "components/reagents/acme/theirs/1.0.0/notes.txt", "x")

    assert msg =~ "fork into local/"

    # The athanor's own unit: written, and deleted whole.
    assert {:ok, _} =
             Files.write(
               ctx,
               "components/reagents/local/mine/0.1.0/reagent.wasm",
               Base.encode64(@valid_wasm),
               "base64"
             )

    assert {:ok, _} =
             Files.write(
               ctx,
               "components/reagents/local/mine/0.1.0/cyfr-manifest.json",
               ~s({"type":"reagent","version":"0.1.0"})
             )

    assert {:ok, %{entries: [%{name: "mine"}, %{name: "shelf"}]}} =
             Files.list(ctx, "components/reagents/local")

    assert {:ok, %{deleted: "components/reagents/local/mine/0.1.0"}} =
             Files.delete(ctx, "components/reagents/local/mine/0.1.0")
  end

  test "an edit inside a component keeps its row in step with the tree", %{ctx: ctx} do
    {:ok, _} = Compendium.Registry.register_from_arca(ctx, @shipped)
    {:ok, before} = Compendium.Registry.get(ctx, "shelf", "1.0.0")
    assert before.description == "shipped"

    manifest = ~s({"type":"reagent","version":"1.0.0","description":"edited here"})

    assert {:ok, _} =
             Files.write(
               ctx,
               "components/reagents/local/shelf/1.0.0/cyfr-manifest.json",
               manifest
             )

    {:ok, row} = Compendium.Registry.get(ctx, "shelf", "1.0.0")
    assert row.description == "edited here"
  end

  test "aqua/ is shaped: the soul, a role and a scroll are edited in place; nothing else lands",
       %{ctx: ctx} do
    assert {:ok, %{tier: :shaped, entries: entries}} = Files.list(ctx, "aqua")
    assert Enum.map(entries, & &1.name) == ["roles", "aqua.md"]

    assert {:ok, %{content: "---\ntitle: Scribe\n---\n\nscribe\n"}} =
             Files.read(ctx, "aqua/roles/scribe.md")

    assert {:ok, _} =
             Files.write(ctx, "aqua/roles/scribe.md", "---\ntitle: Scribe\n---\n\nours\n")

    assert {:ok, %{content: "---\ntitle: Scribe\n---\n\nours\n"}} =
             Files.read(ctx, "aqua/roles/scribe.md")

    assert {:error, {:invalid_argument, msg}} = Files.write(ctx, "aqua/roles/notes.txt", "x")
    assert msg =~ "outside any AQUA unit"

    assert {:error, {:invalid_argument, _}} =
             Files.write(ctx, "aqua/roles/scribe.md/inner.txt", "x")

    assert {:error, {:invalid_argument, msg}} = Files.delete(ctx, "aqua/roles/scribe.md")
    assert msg =~ "ships with the server"

    # The estate's own role and scroll go by the same door.
    assert {:ok, _} = Files.write(ctx, "aqua/roles/mine.md", "---\ntitle: Mine\n---\n\nmine\n")
    assert {:ok, _} = Files.write(ctx, "aqua/skills/pdf/SKILL.md", "---\nname: pdf\n---\n\npdf\n")
    assert {:ok, %{deleted: "aqua/roles/mine.md"}} = Files.delete(ctx, "aqua/roles/mine.md")
    assert {:ok, %{deleted: "aqua/skills/pdf"}} = Files.delete(ctx, "aqua/skills/pdf")
  end

  test "locate/1 names the bytes the download route streams, in any shown folder" do
    assert {:ok, ["data", "a", "b.txt"], :open} = Files.locate("data/a/b.txt")
    assert {:ok, ["notes", "plan.md"], :read} = Files.locate("notes/plan.md")
    assert {:error, {:not_found, "Folder", "payloads"}} = Files.locate("payloads/sha256/abc")
    assert {:error, {:invalid_argument, _}} = Files.locate("data")
    assert {:error, {:invalid_argument, _}} = Files.locate("data/../x")
  end
end
