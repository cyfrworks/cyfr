# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaTemplateTest do
  @moduledoc """
  The template's copy-and-upgrade discipline: `ensure/1` seeds a missing
  copy, `refresh/1` upgrades only a copy the members never touched, and
  `reset/1` is the deliberate path past that guard.
  """

  use ExUnit.Case, async: false

  alias Compendium.AquaTemplate

  setup do
    base = Path.join(System.tmp_dir!(), "aqua_template_#{System.unique_integer([:positive])}")
    seed = Path.join(base, "seed")
    template = Path.join(seed, "aqua")
    File.mkdir_p!(template)

    prev_base = Application.fetch_env!(:cyfr, :base_path)
    prev_seed = Application.fetch_env!(:cyfr, :seed_path)
    Application.put_env(:cyfr, :base_path, Path.join(base, "data"))
    Application.put_env(:cyfr, :seed_path, seed)

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      Application.put_env(:cyfr, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    write_template!(template, "v1")

    ctx = Sanctum.internal_context(user_id: "_seed", athanor_id: "ath_aqua", scope: :athanor)
    {:ok, template: template, ctx: ctx}
  end

  defp write_template!(dir, marker) do
    File.write!(
      Path.join(dir, "agent.json"),
      Jason.encode!(%{"agents" => %{"aqua" => %{"prompt" => "aqua.md", "marker" => marker}}})
    )

    File.write!(Path.join(dir, "aqua.md"), "prompt #{marker}")
  end

  test "ensure copies a missing template once, then leaves the copy alone", %{ctx: ctx} do
    assert :ok = AquaTemplate.ensure(ctx)
    assert {:ok, raw} = Arca.get(ctx, ["aqua", "agent.json"])
    assert raw =~ "v1"

    # A present copy is not re-copied, even after the member edits it.
    :ok = Arca.put(ctx, ["aqua", "agent.json"], ~s({"agents": {}}))
    assert :ok = AquaTemplate.ensure(ctx)
    assert {:ok, ~s({"agents": {}})} = Arca.get(ctx, ["aqua", "agent.json"])
  end

  test "refresh upgrades a pristine copy and leaves an edited one alone", %{
    ctx: ctx,
    template: template
  } do
    assert :ok = AquaTemplate.copy_into(ctx)
    assert {:ok, :current} = AquaTemplate.refresh(ctx)

    # A new release ships a new template: the untouched copy follows it.
    write_template!(template, "v2")
    assert {:ok, :refreshed} = AquaTemplate.refresh(ctx)
    assert {:ok, raw} = Arca.get(ctx, ["aqua", "agent.json"])
    assert raw =~ "v2"
    assert {:ok, :current} = AquaTemplate.refresh(ctx)

    # The members edit their copy; the next shipped template must not
    # clobber their work.
    :ok = Arca.put(ctx, ["aqua", "aqua.md"], "our own prompt")
    write_template!(template, "v3")
    assert {:ok, :modified} = AquaTemplate.refresh(ctx)
    assert {:ok, "our own prompt"} = Arca.get(ctx, ["aqua", "aqua.md"])

    # Reset is the deliberate path to the new template.
    assert :ok = AquaTemplate.reset(ctx)
    assert {:ok, "prompt v3"} = Arca.get(ctx, ["aqua", "aqua.md"])
    assert {:ok, :current} = AquaTemplate.refresh(ctx)
  end

  test "a copy from before stamping is treated as edited", %{ctx: ctx, template: template} do
    # A pre-stamp athanor: agent.json exists, no .seeded_digest.
    :ok = Arca.put(ctx, ["aqua", "agent.json"], ~s({"agents": {}}))

    write_template!(template, "v2")
    assert {:ok, :unstamped} = AquaTemplate.refresh(ctx)
    assert {:ok, ~s({"agents": {}})} = Arca.get(ctx, ["aqua", "agent.json"])
  end

  test "reset produces exactly the shipped set — member-created agents go too", %{
    ctx: ctx,
    template: template
  } do
    assert :ok = AquaTemplate.copy_into(ctx)

    # A member-created agent: its own prompt file, referenced nowhere in the
    # shipped manifest. Before exact-set reset this survived forever, so
    # every refresh against a new template read :modified.
    :ok = Arca.put(ctx, ["aqua", "my_agent.md"], "member's own agent")

    write_template!(template, "v2")
    assert {:ok, :modified} = AquaTemplate.refresh(ctx)
    assert :ok = AquaTemplate.reset(ctx)

    assert {:error, :not_found} = Arca.get(ctx, ["aqua", "my_agent.md"])
    assert {:ok, raw} = Arca.get(ctx, ["aqua", "agent.json"])
    assert raw =~ "v2"
    assert {:ok, :current} = AquaTemplate.refresh(ctx)
  end

  test "reset refuses before deleting anything when no template ships", %{
    ctx: ctx,
    template: template
  } do
    assert :ok = AquaTemplate.copy_into(ctx)
    :ok = Arca.put(ctx, ["aqua", "my_agent.md"], "member's own agent")

    # The install loses its template (empty seed tree): reset must refuse
    # and leave the athanor's copy intact — deleting first would destroy
    # the only agents left in existence.
    File.rm_rf!(template)
    File.mkdir_p!(template)

    assert {:error, :template_missing} = AquaTemplate.reset(ctx)
    assert {:ok, _} = Arca.get(ctx, ["aqua", "agent.json"])
    assert {:ok, "member's own agent"} = Arca.get(ctx, ["aqua", "my_agent.md"])
  end

  test "the stamp never surfaces in the template's file listing", %{ctx: ctx} do
    assert :ok = AquaTemplate.copy_into(ctx)
    assert AquaTemplate.files() == ["agent.json", "aqua.md"]

    # The copy carries the stamp on disk, but the manifest/.md filter every
    # listing applies keeps it out of sight.
    assert Arca.exists?(ctx, ["aqua", ".seeded_digest"])
  end
end
