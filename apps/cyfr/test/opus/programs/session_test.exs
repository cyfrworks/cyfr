# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.SessionTest do
  @moduledoc """
  A start of a program that loads the person's packs, through the box's
  one open (`Opus.Programs.box_open/4`), against the scripted backends
  service (`Cyfr.Test.ScriptedBackends`), which reads each put's stream
  as the keeper does: the copy is held before the one open, put only when
  it is missing, made from the selection as it stands and from the
  athanor's own packs alone, and a start whose copy cannot be made ready
  sends no open.
  """
  use ExUnit.Case, async: false

  alias Arca.Files
  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Opus.Programs

  @root :crypto.strong_rand_bytes(32)
  @generation_key {Arca.ControlPlane, :generation}
  @part_bytes Prima.LocusBackends.bounds().max_pack_part_bytes

  setup do
    Cyfr.Test.Sandbox.setup!()
    Arca.Cache.init()

    base = Path.join(System.tmp_dir!(), "session_packs_#{System.unique_integer([:positive])}")
    Prima.Test.Env.put_app_env(:arca, :base_path, Path.join(base, "data"))
    Prima.Test.Env.put_app_env(:arca, :seed_path, Path.join(base, "seed"))
    File.mkdir_p!(Path.join(base, "seed/aqua"))

    ctx = Sanctum.TestContext.local()
    fake = Scripted.start(self(), @root)

    on_exit(fn ->
      :persistent_term.erase(@generation_key)
      Arca.ControlPlane.record(:unclaimed)
      File.rm_rf!(base)
    end)

    Scripted.supervise_controller(url: fake.url, root: @root, tick_ms: 3_600_000)
    assert_receive {:control, "hello", %{"g" => 1}, %{boot: "-"}}, 2_000
    assert_receive {:control, "reconcile", %{"keep" => []}, _fields}, 2_000
    {:ok, ctx: ctx, actor: Sanctum.Context.actor(ctx), fake: fake}
  end

  # A row whose driver loads the athanor's packs (Claude Code's), held by
  # the test process: its grant and the program its sync defined.
  defp held(ctx, command \\ "cyfr-claude-code npx -y @anthropic-ai/claude-code@2.1.323") do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: "claude-code",
        transport: "program",
        mark: "driven",
        url: nil,
        home: "kept",
        memory_bytes: 1_073_741_824,
        config_json: Jason.encode!(%{"command" => command, "env" => %{}})
      })

    {:ok, grant} =
      Programs.hold(%{athanor_id: ctx.athanor_id, server_id: row.id, epoch: row.epoch})

    assert_receive {:control, "sync", %{"programs" => [program]}, _fields}, 2_000
    {grant, program}
  end

  # One start: a new lifetime of the program, opened by the box for the
  # holder, the test process.
  defp start(grant, holder \\ self()) do
    lifetime =
      Programs.lifetime(grant, %{
        program: Opus.Programs.Definition.program_name(),
        key: "k#{System.unique_integer([:positive])}"
      })

    answer =
      Programs.box_open(lifetime, holder, %{}, System.system_time(:millisecond) + 15_000)

    {lifetime.id, answer}
  end

  # The session messages of packs and the open the service was told of,
  # in the order they arrived, until the open or a close.
  defp told(acc \\ []) do
    receive do
      {:session, type, wire, _fields} when type in ["packs_hold", "packs_put"] ->
        told([{type, wire} | acc])

      {:session, type, wire, _fields} when type in ["open", "close"] ->
        Enum.reverse([{type, wire} | acc])
    after
      5_000 -> Enum.reverse([:silent | acc])
    end
  end

  defp holds(told), do: for({"packs_hold", wire} <- told, do: wire["digest"])

  defp puts(told),
    do: for({"packs_put", wire} <- told, do: {wire["digest"], wire["seq"], wire["last"]})

  defp put_bytes(told),
    do: Enum.join(for({"packs_put", wire} <- told, do: Base.decode64!(wire["part"])))

  defp opened(told), do: for({"open", wire} <- told, do: Map.get(wire, "packs", :none))

  defp manifest_paths(fake, athanor, digest),
    do: fake |> Scripted.generations(athanor) |> Map.fetch!(digest) |> paths()

  defp paths(%{manifest: lines}), do: Enum.map(lines, & &1["path"])

  defp digest(ctx), do: elem(Compendium.pack_digest(ctx, ctx.athanor_id), 1)

  @skill "---\nname: a\ndescription: d\n---\n\nb\n"
  @script "#!/bin/sh\necho ok\n"

  test "a first start is answered missing, puts its copy in parts, and opens once naming the " <>
         "digest; a second start puts nothing",
       %{ctx: ctx, actor: actor, fake: fake} do
    # Past one part, so the copy goes in two.
    big = :binary.copy("z", @part_bytes + 1)
    {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/SKILL.md", @skill)
    {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/run.sh", @script)
    {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/big.txt", big)
    {grant, program} = held(ctx)
    d = digest(ctx)

    {first_lifetime, first} = start(grant)
    first_told = told()
    {second_lifetime, second} = start(grant)
    second_told = told()

    assert %{
             sync_packs: program["packs"],
             first: match?({:ok, %{resumed: false}}, first),
             first_lifetimes: for({_type, wire} <- first_told, uniq: true, do: wire["lifetime"]),
             first_holds: holds(first_told),
             first_puts: puts(first_told),
             first_opened: opened(first_told),
             second: match?({:ok, %{resumed: false}}, second),
             second_lifetimes:
               for({_type, wire} <- second_told, uniq: true, do: wire["lifetime"]),
             second_holds: holds(second_told),
             second_puts: puts(second_told),
             second_opened: opened(second_told)
           } == %{
             sync_packs: true,
             first: true,
             first_lifetimes: [first_lifetime],
             first_holds: [d],
             first_puts: [{d, 0, false}, {d, 1, true}],
             first_opened: [d],
             second: true,
             second_lifetimes: [second_lifetime],
             second_holds: [d],
             second_puts: [],
             second_opened: [d]
           }

    assert Scripted.generations(fake, ctx.athanor_id) == %{
             d => %{
               manifest: [
                 %{
                   "path" => "mine/skills/a/SKILL.md",
                   "size" => byte_size(@skill),
                   "sha256" => Prima.Digest.sha256(@skill),
                   "executable" => false
                 },
                 %{
                   "path" => "mine/skills/a/big.txt",
                   "size" => byte_size(big),
                   "sha256" => Prima.Digest.sha256(big),
                   "executable" => false
                 },
                 %{
                   "path" => "mine/skills/a/run.sh",
                   "size" => byte_size(@script),
                   "sha256" => Prima.Digest.sha256(@script),
                   "executable" => true
                 }
               ],
               files: %{
                 "mine/skills/a/SKILL.md" => @skill,
                 "mine/skills/a/big.txt" => big,
                 "mine/skills/a/run.sh" => @script
               }
             }
           }
  end

  test "a selection changed between the digest and the view begins again from the new one, " <>
         "and a fourth move ends the start in its sentence",
       %{ctx: ctx, actor: actor, fake: fake} do
    {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/SKILL.md", @skill)
    {grant, _program} = held(ctx)
    d0 = digest(ctx)

    # The hold is held at the service while the person writes a file: its
    # answer, missing, is read by a digest the store has moved on from.
    change = fn n ->
      assert_receive {:held, "packs_hold", pid}, 5_000
      {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/n#{n}.md", "#{n}")
      send(pid, :go)
      digest(ctx)
    end

    test = self()
    Scripted.hold(fake, "packs_hold")
    once = Task.async(fn -> start(grant, test) end)
    d1 = change.(1)
    {_lifetime, again} = Task.await(once, 15_000)
    again_told = told()

    # A selection the service holds no copy of, so each hold is missing.
    {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/n2.md", "2")
    d2 = digest(ctx)
    for _n <- 1..4, do: Scripted.hold(fake, "packs_hold")
    moving = Task.async(fn -> start(grant, test) end)
    moved = for n <- 3..6, do: change.(n)
    {_lifetime, ended} = Task.await(moving, 15_000)
    ended_told = told()

    assert %{
             again: match?({:ok, _}, again),
             again_holds: holds(again_told),
             again_puts: puts(again_told),
             again_opened: opened(again_told),
             again_copy: manifest_paths(fake, ctx.athanor_id, d1),
             ended: ended,
             ended_holds: holds(ended_told),
             ended_puts: puts(ended_told),
             ended_opened: opened(ended_told),
             sentence: Prima.Refusal.message(:packs_moved)
           } == %{
             again: true,
             again_holds: [d0, d1],
             again_puts: [{d1, 0, true}],
             again_opened: [d1],
             again_copy: ["mine/skills/a/SKILL.md", "mine/skills/a/n1.md"],
             ended: {:error, :packs_moved},
             ended_holds: [d2 | Enum.drop(moved, -1)],
             ended_puts: [],
             ended_opened: [],
             sentence: "Your packs changed while this program was starting; start it again."
           }

    assert ended_told |> List.last() |> elem(0) == "close"
    assert Map.keys(Scripted.generations(fake, ctx.athanor_id)) == [d1]
  end

  test "a pack switched off is out of the next start's copy", %{
    ctx: ctx,
    actor: actor,
    fake: fake
  } do
    {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/SKILL.md", @skill)
    {:ok, _} = Files.write(actor, "aqua/scrolls/garden/skills/roses/SKILL.md", @skill)
    {grant, _program} = held(ctx)
    on = digest(ctx)
    {_lifetime, {:ok, _}} = start(grant)
    told()

    :ok = Compendium.switch_pack(ctx, "garden", false)
    off = digest(ctx)
    {_lifetime, {:ok, _}} = start(grant)
    off_told = told()

    assert %{
             on: manifest_paths(fake, ctx.athanor_id, on),
             off_puts: puts(off_told),
             off: manifest_paths(fake, ctx.athanor_id, off),
             opened: opened(off_told)
           } == %{
             on: ["garden/skills/roses/SKILL.md", "mine/skills/a/SKILL.md"],
             off_puts: [{off, 0, true}],
             off: ["mine/skills/a/SKILL.md"],
             opened: [off]
           }
  end

  test "another athanor's packs never reach the put", %{ctx: ctx, actor: actor, fake: fake} do
    {_a, other} = Sanctum.TestContext.two_contexts()
    secret = "their own words, never put"

    {:ok, _} =
      Files.write(Sanctum.Context.actor(other), "aqua/scrolls/mine/skills/a/SKILL.md", secret)

    {:ok, _} =
      Files.write(Sanctum.Context.actor(other), "aqua/scrolls/theirs/skills/t/SKILL.md", secret)

    {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/SKILL.md", @skill)
    {grant, _program} = held(ctx)
    d = digest(ctx)
    {_lifetime, {:ok, _}} = start(grant)
    put = told()

    assert %{
             copy: Scripted.generations(fake, ctx.athanor_id)[d][:files],
             theirs: Scripted.generations(fake, other.athanor_id),
             secret_put: String.contains?(put_bytes(put), secret)
           } == %{
             copy: %{"mine/skills/a/SKILL.md" => @skill},
             theirs: %{},
             secret_put: false
           }
  end

  test "a Files write into mine followed by a start is a new digest, put again", %{
    ctx: ctx,
    actor: actor,
    fake: fake
  } do
    {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/SKILL.md", @skill)
    {grant, _program} = held(ctx)
    before = digest(ctx)
    {_lifetime, {:ok, _}} = start(grant)
    told()

    {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/notes.md", "written since")
    written = digest(ctx)
    {_lifetime, {:ok, _}} = start(grant)
    again = told()

    assert %{
             moved: written != before,
             holds: holds(again),
             puts: puts(again),
             opened: opened(again),
             copy: Scripted.generations(fake, ctx.athanor_id)[written][:files]
           } == %{
             moved: true,
             holds: [written],
             puts: [{written, 0, true}],
             opened: [written],
             copy: %{
               "mine/skills/a/SKILL.md" => @skill,
               "mine/skills/a/notes.md" => "written since"
             }
           }
  end

  test "a row that does not load packs holds nothing and its open names none", %{
    ctx: ctx,
    actor: actor
  } do
    {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/SKILL.md", @skill)
    {grant, program} = held(ctx, "npx -y @modelcontextprotocol/server-github")
    {_lifetime, answer} = start(grant)
    assert {:ok, %{resumed: false}} = answer
    assert [{"open", open}] = told()

    assert %{sync_packs: Map.has_key?(program, "packs"), open_packs: Map.has_key?(open, "packs")} ==
             %{sync_packs: false, open_packs: false}
  end

  for {type, code} <- [{"packs_put", "packs_refused"}, {"packs_hold", "unavailable"}] do
    @tag type: type, code: code
    test "a #{type} refused #{code} ends the start in its sentence, and no open is sent", %{
      ctx: ctx,
      actor: actor,
      fake: fake,
      type: type,
      code: code
    } do
      {:ok, _} = Files.write(actor, "aqua/scrolls/mine/skills/a/SKILL.md", @skill)
      {grant, _program} = held(ctx)
      Scripted.refuse_once(fake, type, code)
      {_lifetime, answer} = start(grant)
      told = told()

      assert %{
               answer: answer,
               opened: opened(told),
               ended_by: told |> List.last() |> elem(0),
               copies: Scripted.generations(fake, ctx.athanor_id),
               sentence: Prima.Refusal.classify(:packs_unready)
             } == %{
               answer: {:error, :packs_unready},
               opened: [],
               ended_by: "close",
               copies: %{},
               sentence: %Prima.Refusal{
                 class: :unavailable,
                 reason: :packs_unready,
                 message: "Your packs could not be made ready for this program."
               }
             }
    end
  end
end
