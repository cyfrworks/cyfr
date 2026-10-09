# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.CanvasTest do
  @moduledoc """
  The `canvas` tool: Compendium's, with five operations whose kinds,
  planes and permission are the operation table's — the two reads and the
  write on both planes, activation and restore from outside any chain —
  and no consent, standing or resource annotation. Each action is
  `Compendium.Canvas`'s, and each refusal is one of `Prima.Refusal`'s
  classes: `invalid_argument` for a shape, size or grammar, `not_found`
  for a canvas, `conflict` for a name another tincture holds or a stale
  document, `forbidden` with its code at the end of its sentence, and the
  fixed `consent_required` and `not_owner`.
  """

  use ExUnit.Case, async: false

  alias Compendium.Providers.Canvas
  alias Sanctum.Context

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Arca.Cache.init()

    base = Path.join(System.tmp_dir!(), "canvas_tool_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      if prev, do: Application.put_env(:arca, :base_path, prev)
      File.rm_rf!(base)
    end)

    {:ok, ctx: person_ctx()}
  end

  defp person_ctx do
    Context.build(
      user_id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
      athanor_id: Sanctum.TestContext.athanor_id(),
      permissions: Context.person_permissions(),
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
    |> Sanctum.TestContext.via(:prism)
  end

  defp call(ctx, action, args \\ %{}),
    do: Canvas.handle("canvas", ctx, Map.put(args, "action", action))

  defp operations do
    [tool] = Canvas.tools()
    Map.new(tool.operations, &{&1.action, &1})
  end

  describe "the declaration" do
    test "five operations, with the operation table's kinds, planes and permission" do
      [tool] = Canvas.tools()
      assert tool.name == "canvas"
      assert Canvas.service() == "compendium"

      ops = operations()
      assert Enum.sort(Map.keys(ops)) == ~w(activate catalog restore versions write)

      assert {ops["catalog"].kind, ops["catalog"].planes, ops["catalog"].permission} ==
               {:read, [:external, :in_chain], nil}

      assert {ops["versions"].kind, ops["versions"].planes, ops["versions"].permission} ==
               {:read, [:external, :in_chain], nil}

      assert {ops["write"].kind, ops["write"].planes, ops["write"].permission} ==
               {:write, [:external, :in_chain], :execute}

      assert {ops["activate"].kind, ops["activate"].planes, ops["activate"].permission} ==
               {:write, [:external], nil}

      assert {ops["restore"].kind, ops["restore"].planes, ops["restore"].permission} ==
               {:write, [:external], nil}

      # As the layout's operations, none carries a consent, standing or
      # resource annotation: the agent's consent names the keys it reaches.
      for {_action, op} <- ops do
        assert {op.consent, op.standing, op.resource} == {nil, nil, nil}
      end
    end

    test "each takes the arguments the table names, all required, and JSON as a JSON value" do
      args = fn action -> Map.new(operations()[action].args, &{&1.name, &1}) end

      assert args.("catalog") == %{}
      assert Map.keys(args.("versions")) == ["canvas"]
      assert Enum.sort(Map.keys(args.("write"))) == ~w(module name streams)
      assert Enum.sort(Map.keys(args.("activate"))) == ~w(canvas frame outcome version)
      assert Map.keys(args.("restore")) == ["canvas"]

      for action <- ~w(versions write activate restore), {_name, arg} <- args.(action) do
        assert arg.required, "#{action}.#{arg.name} is required"
      end

      assert args.("write")["streams"].type == :json
      assert args.("write")["module"].type == :string
      assert args.("activate")["outcome"].enum == ~w(tree no_tree died)
    end

    test "the provider is rostered after the layout's, so the gate serves it, and activation " <>
           "and restore never from a chain" do
      providers = Application.fetch_env!(:cyfr, :tool_providers)
      assert Canvas in providers

      assert Enum.find_index(providers, &(&1 == Canvas)) ==
               Enum.find_index(providers, &(&1 == Compendium.Providers.Layout)) + 1

      assert {:ok, {Canvas, _meta}} = Grimoire.lookup("canvas")

      for action <- ~w(catalog versions write),
          do: assert(Grimoire.chain_reachable?("canvas", action))

      for action <- ~w(activate restore), do: assert(Grimoire.in_chain_refused?("canvas", action))
    end
  end

  describe "the actions" do
    test "catalog answers the toolkit majors and the readable streams", %{ctx: ctx} do
      assert {:ok, %{toolkit: [1], streams: streams}} = call(ctx, "catalog")
      assert call(ctx, "catalog") == Compendium.Canvas.catalog(ctx)

      {:ok, {_provider, feeds}} = Grimoire.Catalog.lookup_stream("feed.results")
      {:ok, {_provider, runs}} = Grimoire.Catalog.lookup_stream("runs.changes")

      assert streams == [
               %{
                 name: "feed.results",
                 subject: ~S"\A[a-z0-9][a-z0-9-]{0,47}\z",
                 shape: feeds.shape,
                 filter: "feed",
                 refresh: true
               },
               %{
                 name: "runs.changes",
                 subject: nil,
                 shape: runs.shape,
                 filter: nil,
                 refresh: true
               }
             ]
    end

    test "write, versions and restore answer through the tool", %{ctx: ctx} do
      assert {:ok,
              %{canvas: "markets", version: "0.1.0", reference: "tincture:local.markets:0.1.0"}} =
               call(ctx, "write", %{"name" => "markets", "module" => "// m", "streams" => []})

      assert {:ok, %{canvas: "markets", document: %{allocated: "0.1.0"}, revision: 1}} =
               call(ctx, "versions", %{"canvas" => "markets"})

      assert {:error, {:not_found, "Kept version of canvas", "markets"}} =
               call(ctx, "restore", %{"canvas" => "markets"})
    end

    test "an unknown tool is refused" do
      assert Canvas.handle("canvases", person_ctx(), %{"action" => "catalog"}) ==
               {:error, :unknown_tool}
    end
  end

  describe "the refusals" do
    test "each is one of the table's classes", %{ctx: ctx} do
      class = fn {:error, reason} -> Prima.Refusal.classify(reason).class end

      # A shape, a size or a grammar.
      for args <- [
            %{"name" => "Markets", "module" => "// m", "streams" => []},
            %{"name" => "markets", "module" => String.duplicate("a", 262_145), "streams" => []},
            %{"name" => "markets", "module" => "// m", "streams" => [%{"name" => "x"}]},
            %{"name" => "markets", "module" => "// m", "streams" => "runs.changes"}
          ] do
        assert class.(call(ctx, "write", args)) == :invalid_argument
      end

      assert class.(call(ctx, "versions", %{"canvas" => "absent"})) == :not_found

      assert class.(
               call(ctx, "activate", %{
                 "canvas" => "markets",
                 "version" => "1.0.0",
                 "frame" => "frm_never_trialled",
                 "outcome" => "tree"
               })
             ) == :not_found

      assert class.(call(ctx, "restore", %{"canvas" => "absent"})) == :not_found

      assert class.(call(ctx, "activate", %{"canvas" => "markets", "outcome" => "won"})) ==
               :invalid_argument

      # A stale document is a conflict, as a name another tincture holds is.
      assert class.({:error, {:conflict, "the canvas's versions changed"}}) == :conflict
      assert class.({:error, :consent_required}) == :consent_required
      assert class.({:error, :not_owner}) == :not_owner

      forbidden = %Prima.Refusal{
        class: :forbidden,
        reason: :not_validated,
        message: "That frame holds no validation credential (not_validated)"
      }

      assert Prima.Refusal.classify(forbidden) == forbidden
    end

    test "the gate answers the tool's refusal, classed with the sentence the tool wrote",
         %{ctx: ctx} do
      assert {:error, {:not_found, "Canvas", "absent"} = absent} =
               Grimoire.call_external("canvas", ctx, %{
                 "action" => "versions",
                 "canvas" => "absent"
               })

      assert %Prima.Refusal{class: :not_found, message: "Canvas not found: absent"} =
               Prima.Refusal.classify(absent)

      assert {:error, {:invalid_argument, sentence} = unreadable} =
               Grimoire.call_external("canvas", ctx, %{
                 "action" => "write",
                 "name" => "markets",
                 "module" => "// m",
                 "streams" => [%{"name" => "mcp_servers.changes"}]
               })

      assert %Prima.Refusal{class: :invalid_argument, message: ^sentence} =
               Prima.Refusal.classify(unreadable)

      assert sentence =~ "mcp_servers.changes, which a canvas cannot read"
    end
  end
end
