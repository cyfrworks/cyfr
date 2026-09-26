# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.LayoutTest do
  @moduledoc """
  The `layout` tool: `get` answers the caller's document or the shipped
  default, `edit` holds a whole document to the layout's shape and
  publishes it fenced over the revision read; an edit over a newer
  revision is refused, a document that names an operation or a stream is
  refused, a tincture nobody installed is kept; `Compendium.layout/2` is
  the console's read of the same document.
  """
  use ExUnit.Case, async: false

  alias Compendium.Providers.Layout
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

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

  defp document(desktop \\ "tincture:local.desktop") do
    %{
      "version" => 1,
      "postures" => %{
        "desk" => %{
          "desktop" => desktop,
          "slots" => [
            %{
              "id" => "vault",
              "tincture" => "tincture:local.vault",
              "size" => "icon",
              "order" => 0
            },
            %{
              "id" => "gone",
              "tincture" => "tincture:acme.never-installed",
              "size" => "card",
              "order" => 1
            }
          ],
          "floating" => []
        }
      }
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

    test "the provider is rostered, so the gate serves it" do
      assert Layout in Application.fetch_env!(:cyfr, :tool_providers)
      assert {:ok, {Layout, _meta}} = Grimoire.lookup("layout")
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

      assert {:ok, %{posture: "hand", arrangement: %{"desktop" => "tincture:local.desktop"}}} =
               get(ctx, %{"posture" => "hand"})
    end

    test "a posture the document does not name reads as the default's", %{ctx: ctx} do
      {:ok, _} = edit(ctx, document(), 0)

      assert {:ok, %{arrangement: %{"desktop" => "tincture:local.desktop", "slots" => []}}} =
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

      # A tincture nobody installed is kept, for the desktop to draw as a placeholder.
      assert Enum.any?(
               answer.arrangement["slots"],
               &(&1["tincture"] == "tincture:acme.never-installed")
             )

      assert {:ok, %{revision: 1, arrangement: %{desktop: "tincture:local.desktop"}} = read} =
               Compendium.layout(ctx, "desk")

      assert %Prima.Layout{} = read.document
    end

    test "an edit over a newer revision is refused and changes nothing", %{ctx: ctx} do
      {:ok, %{revision: 1}} = edit(ctx, document(), 0)
      {:ok, %{revision: 2}} = edit(ctx, document("tincture:local.second"), 1)

      assert {:error, {:conflict, sentence}} = edit(ctx, document("tincture:local.late"), 1)
      assert sentence =~ "revision 1"
      assert {:error, {:conflict, _}} = edit(ctx, document("tincture:local.late"), 0)

      assert {:ok, %{revision: 2, arrangement: %{"desktop" => "tincture:local.second"}}} =
               get(ctx, %{"posture" => "desk"})
    end

    test "a layout can only arrange: an operation or a stream in it is refused", %{ctx: ctx} do
      [slot | _] = document()["postures"]["desk"]["slots"]

      with_action =
        put_in(document(), ["postures", "desk", "slots"], [Map.put(slot, "action", "vault.list")])

      with_stream = put_in(document(), ["postures", "desk", "stream"], "vault.status")

      assert {:error, {:invalid_argument, _}} = edit(ctx, with_action, 0)
      assert {:error, {:invalid_argument, _}} = edit(ctx, with_stream, 0)
      assert {:error, {:invalid_argument, _}} = edit(ctx, %{"version" => 2}, 0)
      assert {:error, {:invalid_argument, _}} = edit(ctx, document(), -1)
      assert {:ok, %{shipped_default: true}} = get(ctx)
    end

    test "each person arranges their own", %{ctx: ctx} do
      other = person_ctx()
      {:ok, %{revision: 1}} = edit(ctx, document("tincture:local.mine"), 0)

      assert {:ok, %{shipped_default: true, revision: 0}} = get(other)
      assert {:ok, %{revision: 1}} = edit(other, document("tincture:local.theirs"), 0)

      assert {:ok, %{arrangement: %{desktop: "tincture:local.mine"}}} =
               Compendium.layout(ctx, "desk")

      assert {:ok, %{arrangement: %{desktop: "tincture:local.theirs"}}} =
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
