# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.LayoutTest do
  @moduledoc """
  The `layout` tool: `get` answers the caller's document or the shipped
  default, `edit` holds a whole document to the layout's shape and
  publishes it fenced over the revision read; an edit over a newer
  revision is refused, a document that names an operation or a stream is
  refused and so is a version-1 document, a tincture nobody installed is
  kept; `Compendium.layout/2` is the console's read of the same document,
  each posture arranging every canvas in order.
  """
  use ExUnit.Case, async: false

  alias Compendium.Providers.Layout
  alias Sanctum.Context

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    base = Path.join(System.tmp_dir!(), "layout_tool_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      if prev, do: Application.put_env(:arca, :base_path, prev)
      File.rm_rf!(base)
    end)

    {:ok, ctx: person_ctx()}
  end

  defp person_ctx(user_id \\ Prima.UUID7.generate_id(Prima.PersonId.prefix())) do
    Context.build(
      user_id: user_id,
      athanor_id: Sanctum.TestContext.athanor_id(),
      permissions: Context.person_permissions(),
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  # Two canvases: `home` on `canvas`, placing the vault as a column and a
  # tincture nobody installed in full on the desk; and `notes`, placing
  # nothing.
  defp document(canvas \\ "tincture:local.canvas") do
    %{
      "version" => 2,
      "canvases" => [
        %{
          "id" => "home",
          "tincture" => canvas,
          "postures" => %{
            "desk" => %{
              "apps" => [
                %{"tincture" => "tincture:local.vault", "mode" => "column", "order" => 0},
                %{"tincture" => "tincture:acme.never-installed", "mode" => "full", "order" => 1}
              ],
              "floating" => []
            }
          }
        },
        %{"id" => "notes", "tincture" => "tincture:local.notes-canvas", "postures" => %{}}
      ]
    }
  end

  defp get(ctx, args \\ %{}), do: Layout.handle("layout", ctx, Map.put(args, "action", "get"))

  defp edit(ctx, document, revision),
    do:
      Layout.handle("layout", ctx, %{
        "action" => "edit",
        "document" => document,
        "revision" => revision
      })

  describe "the declaration" do
    test "get reads and edit writes, on both planes, and neither takes an operation or a stream" do
      [tool] = Layout.tools()
      assert tool.name == "layout"
      assert Layout.service() == "compendium"

      ops = Map.new(tool.operations, &{&1.action, &1})
      assert Enum.sort(Map.keys(ops)) == ["edit", "get"]
      assert ops["get"].kind == :read
      assert ops["edit"].kind == :write

      for {_action, op} <- ops do
        assert op.planes == [:external, :in_chain]
        refute Enum.any?(op.args, &(&1.name in ["operation", "stream", "grant"]))
      end
    end

    test "the descriptions name canvases, apps and floating tinctures, never the desktop" do
      [tool] = Layout.tools()

      described =
        [
          tool.description
          | Enum.flat_map(tool.operations, fn op ->
              [op.description | Enum.map(op.args, & &1.description)]
            end)
        ]
        |> Enum.join(" ")

      for word <- ["canvases", "apps", "floating"], do: assert(described =~ word)
      for word <- ["desktop", "slots", "card"], do: refute(described =~ word)
    end

    test "the provider is rostered, so the gate serves it" do
      assert Layout in Application.fetch_env!(:sanctum, :tool_providers)
      assert {:ok, {Layout, _meta}} = Sanctum.Catalog.lookup("layout")
    end
  end

  describe "get" do
    test "a person who never arranged one reads the shipped default at revision 0", %{ctx: ctx} do
      default = Prima.Layout.default()

      assert {:ok, answer} = get(ctx)
      assert answer.document == Prima.Layout.to_json(default)
      assert answer.revision == 0
      assert answer.digest == Prima.Layout.digest(default)
      assert answer.shipped_default

      assert {:ok,
              %{
                posture: "hand",
                arrangement: [
                  %{
                    "id" => "home",
                    "tincture" => "tincture:local.canvas",
                    "apps" => [],
                    "floating" => []
                  }
                ]
              }} = get(ctx, %{"posture" => "hand"})
    end

    test "each canvas is arranged in order, and a posture a canvas does not name places nothing",
         %{ctx: ctx} do
      {:ok, _} = edit(ctx, document(), 0)

      assert {:ok, %{arrangement: [home, notes]}} = get(ctx, %{"posture" => "desk"})

      assert home == %{
               "id" => "home",
               "tincture" => "tincture:local.canvas",
               "apps" => [
                 %{"tincture" => "tincture:local.vault", "mode" => "column", "order" => 0},
                 %{"tincture" => "tincture:acme.never-installed", "mode" => "full", "order" => 1}
               ],
               "floating" => []
             }

      assert notes == %{
               "id" => "notes",
               "tincture" => "tincture:local.notes-canvas",
               "apps" => [],
               "floating" => []
             }

      assert {:ok, %{arrangement: [%{"apps" => []}, %{"apps" => []}]}} =
               get(ctx, %{"posture" => "hand"})

      assert {:error, {:invalid_argument, _}} = get(ctx, %{"posture" => "wall"})
    end
  end

  describe "edit" do
    test "publishes the document, which get and the facade then read", %{ctx: ctx} do
      assert {:ok, %{revision: 1, digest: digest}} = edit(ctx, document(), 0)

      assert {:ok, answer} = get(ctx, %{"posture" => "desk"})
      assert answer.revision == 1
      assert answer.digest == digest
      refute answer.shipped_default
      assert answer.document == document()

      # A tincture nobody installed is kept.
      assert Enum.any?(
               hd(answer.arrangement)["apps"],
               &(&1["tincture"] == "tincture:acme.never-installed")
             )

      assert {:ok,
              %{
                revision: 1,
                arrangement: [%{id: "home", tincture: "tincture:local.canvas"}, %{id: "notes"}]
              } = read} = Compendium.layout(ctx, "desk")

      assert %Prima.Layout{} = read.document
    end

    test "an edit over a newer revision is refused and changes nothing", %{ctx: ctx} do
      {:ok, %{revision: 1}} = edit(ctx, document(), 0)
      {:ok, %{revision: 2}} = edit(ctx, document("tincture:local.second"), 1)

      assert {:error, {:conflict, sentence}} = edit(ctx, document("tincture:local.late"), 1)
      assert sentence =~ "revision 1"
      assert {:error, {:conflict, _}} = edit(ctx, document("tincture:local.late"), 0)

      assert {:ok, %{revision: 2, arrangement: [%{"tincture" => "tincture:local.second"} | _]}} =
               get(ctx, %{"posture" => "desk"})
    end

    test "a layout can only arrange: an operation, a stream or a version-1 document is refused",
         %{ctx: ctx} do
      [app | _] = hd(document()["canvases"])["postures"]["desk"]["apps"]

      with_action =
        update_in(document(), ["canvases"], fn [home | rest] ->
          [
            put_in(home, ["postures", "desk", "apps"], [Map.put(app, "action", "vault.list")])
            | rest
          ]
        end)

      with_stream =
        update_in(document(), ["canvases"], fn [home | rest] ->
          [put_in(home, ["postures", "desk", "stream"], "vault.status") | rest]
        end)

      version_one = %{
        "version" => 1,
        "postures" => %{
          "desk" => %{"desktop" => "tincture:local.canvas", "slots" => [], "floating" => []}
        }
      }

      assert {:error, {:invalid_argument, _}} = edit(ctx, with_action, 0)
      assert {:error, {:invalid_argument, _}} = edit(ctx, with_stream, 0)
      assert {:error, {:invalid_argument, sentence}} = edit(ctx, version_one, 0)
      assert sentence =~ "version must be 2"
      assert {:error, {:invalid_argument, _}} = edit(ctx, %{"version" => 2}, 0)
      assert {:error, {:invalid_argument, _}} = edit(ctx, document(), -1)
      assert {:ok, %{shipped_default: true}} = get(ctx)
    end

    test "an empty layout is published, and arranges no canvas", %{ctx: ctx} do
      assert {:ok, %{revision: 1}} = edit(ctx, %{"version" => 2, "canvases" => []}, 0)
      assert {:ok, %{arrangement: [], shipped_default: false}} = get(ctx, %{"posture" => "desk"})
      assert {:ok, %{arrangement: []}} = Compendium.layout(ctx, "hand")
    end

    test "a published layout is announced on the person's own topic, a refused one is not",
         %{ctx: ctx} do
      actor = Context.actor(ctx)
      other = person_ctx()
      :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.layouts(actor, ctx.user_id))
      :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.layouts(actor, other.user_id))
      user_id = ctx.user_id
      athanor_id = ctx.athanor_id

      {:ok, %{revision: 1}} = edit(ctx, document(), 0)

      assert_receive %Cyfr.Bus.LayoutPublished{
        kind: :published,
        user_id: ^user_id,
        athanor_id: ^athanor_id,
        revision: 1
      }

      {:error, {:conflict, _}} = edit(ctx, document("tincture:local.late"), 0)
      refute_receive %Cyfr.Bus.LayoutPublished{}, 50

      {:ok, %{revision: 1}} = edit(other, document(), 0)
      other_id = other.user_id
      assert_receive %Cyfr.Bus.LayoutPublished{user_id: ^other_id}
      refute_receive %Cyfr.Bus.LayoutPublished{}, 50
    end

    test "each person arranges their own", %{ctx: ctx} do
      other = person_ctx()
      {:ok, %{revision: 1}} = edit(ctx, document("tincture:local.mine"), 0)

      assert {:ok, %{shipped_default: true, revision: 0}} = get(other)
      assert {:ok, %{revision: 1}} = edit(other, document("tincture:local.theirs"), 0)

      assert {:ok, %{arrangement: [%{tincture: "tincture:local.mine"} | _]}} =
               Compendium.layout(ctx, "desk")

      assert {:ok, %{arrangement: [%{tincture: "tincture:local.theirs"} | _]}} =
               Compendium.layout(other, "desk")
    end
  end

  test "a caller that is not a person has no layout" do
    server = Sanctum.TestContext.local()

    assert {:error, {:invalid_argument, _}} = get(server)
    assert {:error, {:invalid_argument, _}} = edit(server, document(), 0)
    assert {:error, {:invalid_argument, _}} = Compendium.layout(server, "desk")
  end
end
