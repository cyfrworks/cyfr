# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Gate.BulkContentRefusalLogTest do
  @moduledoc """
  A refused call's request-log row holds its bulk content as size and
  digest too: a note's body, a canvas's files the handler refuses, a
  source edit the handler refuses (whose sentence names the edit by
  position and kind, never its content), and a call refused at admission
  whose arguments are valid.
  """

  use ExUnit.Case, async: false

  alias Prima.Test.AuthorityFixtures

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    base =
      Path.join(
        System.tmp_dir!(),
        "bulk_refusal_log_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      )

    previous = Application.fetch_env(:arca, :base_path)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arca, :base_path, value)
        :error -> Application.delete_env(:arca, :base_path)
      end

      File.rm_rf!(base)
    end)

    Application.put_env(:arca, :base_path, base)
    Cyfr.Test.Sandbox.stop_work_on_exit()

    {:ok, ctx: Sanctum.TestContext.local(:prism)}
  end

  test "a canvas's files the handler refuses are logged each as its size and digest", %{
    ctx: ctx
  } do
    page = "<html><body>BULK_CANVAS_PAGE_CONTENT_MARKER</body></html>"
    script = "// BULK_CANVAS_SCRIPT_CONTENT_MARKER"

    args = %{
      "action" => "write",
      "name" => "INVALID",
      "template" => "vanilla",
      "files" => %{"index.html" => page, "app.js" => script},
      "streams" => []
    }

    # The declaration accepts this call. The handler refuses its component
    # name, so no version is written and the request log still closes.
    {:ok, {_provider, definition}} = Sanctum.Catalog.lookup("canvas")
    assert {:ok, ^args} = Prima.Operation.cast(definition, args)
    call_id = Prima.UUID7.generate_id("call")

    assert {:error, {:invalid_argument, message}} =
             Sanctum.Gate.call_external("canvas", ctx, args, call_id: call_id)

    assert message =~ "canvas's name"
    assert %{status: "error", input: input} = Arca.Repo.get(Arca.Schemas.McpLog, call_id)

    refute input =~ "BULK_CANVAS_PAGE_CONTENT_MARKER"
    refute input =~ "BULK_CANVAS_SCRIPT_CONTENT_MARKER"

    assert Jason.decode!(input)["files"] == %{
             "index.html" => measured(page),
             "app.js" => measured(script)
           }
  end

  test "a source edit the handler refuses names the edit, never its content, in the request log's error",
       %{ctx: ctx} do
    unit = Compendium.ComponentPath.version_dir("catalyst", "local", "bulk-probe", "0.1.0")

    Arca.Test.UnitFixtures.lay_unit!(ctx, unit, [
      {"cyfr-manifest.json", ~s({"name":"bulk-probe"})},
      {"src/lib.rs", "fn original() {}"}
    ])

    content = "BULK_SOURCE_EDIT_CONTENT_MARKER"

    args = %{
      "action" => "edit",
      "path" => Enum.join(unit ++ ["src", "lib.rs"], "/"),
      "edits" => [%{"action" => "replace", "start" => 1, "content" => content}]
    }

    # `end` is optional in the declaration, but replace requires it in the
    # handler. This enters the handler's edit-shape refusal after admission.
    {:ok, {_provider, definition}} = Sanctum.Catalog.lookup("source")
    assert {:ok, ^args} = Prima.Operation.cast(definition, args)
    call_id = Prima.UUID7.generate_id("call")
    lineage = Cyfr.Test.AttemptFixtures.lineage!(ctx)

    assert {:error, {:invalid_argument, message}} =
             Sanctum.Gate.call_in_chain(
               "source",
               Sanctum.Context.enter_guest(ctx),
               args,
               source_authority(),
               call_id: call_id,
               lineage: lineage
             )

    assert message =~ "edit 1 (replace)"
    refute message =~ content

    assert %{status: "error", input: input, error: error} =
             Arca.Repo.get(Arca.Schemas.McpLog, call_id)

    assert [%{"content" => logged}] = Jason.decode!(input)["edits"]
    assert logged == measured(content)
    refute error =~ content
  end

  test "an admission refusal retains a valid bulk argument's size and digest", %{ctx: ctx} do
    content = "BULK_REFUSED_SOURCE_CONTENT_MARKER"

    args = %{
      "action" => "write",
      "path" => "components/catalysts/local/bulk-probe/0.1.0/src/refused.rs",
      "content" => content
    }

    {:ok, {_provider, definition}} = Sanctum.Catalog.lookup("source")
    assert {:ok, ^args} = Prima.Operation.cast(definition, args)
    call_id = Prima.UUID7.generate_id("call")

    # Source writes belong to the in-chain plane. This valid call is
    # refused at admission on the external plane, before any handler runs.
    assert {:error,
            %Prima.Refusal{
              stage: :admission,
              reason: {:unknown_action, "source.write"}
            }} = Sanctum.Gate.call_external("source", ctx, args, call_id: call_id)

    assert %{status: "error", input: input} = Arca.Repo.get(Arca.Schemas.McpLog, call_id)
    assert Jason.decode!(input)["content"] == measured(content)
  end

  for action <- ["keep", "pin"] do
    @action action
    test "a note's body a refused notes.#{action} carries is logged as its size and digest", %{
      ctx: ctx
    } do
      content = "BULK_NOTE_BODY_MARKER"
      args = %{"action" => @action, "name" => "../not-a-note", "content" => content}
      {:ok, {_provider, definition}} = Sanctum.Catalog.lookup("notes")
      assert {:ok, ^args} = Prima.Operation.cast(definition, args)
      call_id = Prima.UUID7.generate_id("call")

      assert {:error, _} = Sanctum.Gate.call_external("notes", ctx, args, call_id: call_id)
      assert %{status: "error", input: input} = Arca.Repo.get(Arca.Schemas.McpLog, call_id)
      refute input =~ content
      assert Jason.decode!(input)["content"] == measured(content)
    end
  end

  defp source_authority do
    source = AuthorityFixtures.formula_ref()

    graph =
      put_in(
        AuthorityFixtures.graph_map(),
        ["nodes", source, "edges", "@ingress", "tools"],
        ["source.edit"]
      )

    {:ok, blob} = Prima.Authority.Blob.parse(graph)

    {:ok, authority} =
      Prima.Authority.root(AuthorityFixtures.profile(), blob,
        ceiling: AuthorityFixtures.ceiling()
      )

    authority
  end

  defp measured(bytes) do
    %{
      "size" => byte_size(bytes),
      "digest" => "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    }
  end
end
