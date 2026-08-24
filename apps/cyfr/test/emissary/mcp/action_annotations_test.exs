# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ActionAnnotationsTest do
  use ExUnit.Case, async: true

  alias Emissary.MCP.ActionAnnotations

  @annotation %{
    kind: :write,
    planes: [:external, :in_chain],
    auth: :anonymous,
    permission: :admin,
    consent: :staging,
    scope: :platform
  }
  @actions %{"create" => @annotation, "list" => %{kind: :read, planes: [:external]}}

  @provider_shape %{name: "thing", input_schema: %{}, annotations: %{actions: @actions}}
  @meta_shape %{annotations: %{actions: @actions}, description: "cached"}
  @wire_shape %{"name" => "thing", "inputSchema" => %{}, "annotations" => %{actions: @actions}}

  @sources [@provider_shape, @meta_shape, @wire_shape]

  test "every accessor answers the same across all three source shapes" do
    for source <- @sources do
      assert ActionAnnotations.actions_of(source) == @actions
      assert ActionAnnotations.annotation(source, "create") == @annotation
      assert ActionAnnotations.kind(source, "create") == :write
      assert ActionAnnotations.planes(source, "create") == [:external, :in_chain]
      assert ActionAnnotations.auth(source, "create") == :anonymous
      assert ActionAnnotations.permission(source, "create") == :admin
      assert ActionAnnotations.consent(source, "create") == :staging
      assert ActionAnnotations.scope(source, "create") == :platform
    end
  end

  test "absence fails closed" do
    for source <- @sources do
      assert ActionAnnotations.annotation(source, "missing") == nil
      assert ActionAnnotations.annotation(source, nil) == nil
      assert ActionAnnotations.kind(source, "missing") == nil
      assert ActionAnnotations.planes(source, "missing") == []
      assert ActionAnnotations.auth(source, "missing") == :required
      assert ActionAnnotations.permission(source, "missing") == nil
      assert ActionAnnotations.consent(source, "missing") == nil
      assert ActionAnnotations.scope(source, "missing") == nil
    end

    assert ActionAnnotations.actions_of(%{}) == %{}
    assert ActionAnnotations.actions_of(%{"annotations" => nil}) == %{}
    assert ActionAnnotations.actions_of(%{annotations: nil}) == %{}
    assert ActionAnnotations.planes(%{}, "x") == []
    assert ActionAnnotations.auth(%{"annotations" => nil}, "x") == :required
  end

  test "defaults inside a declared annotation" do
    source = %{annotations: %{actions: %{"list" => %{kind: :read, planes: [:external]}}}}
    assert ActionAnnotations.auth(source, "list") == :required
    assert ActionAnnotations.permission(source, "list") == nil
    assert ActionAnnotations.consent(source, "list") == nil
    assert ActionAnnotations.scope(source, "list") == nil
  end

  test "a kind that is not an atom is not a kind" do
    source = %{annotations: %{actions: %{"x" => %{kind: "write"}}}}
    assert ActionAnnotations.kind(source, "x") == nil
  end

  test "declared_actions/1 accepts only the provider spelling" do
    assert ActionAnnotations.declared_actions(@provider_shape) == @actions
    assert ActionAnnotations.declared_actions(%{"annotations" => %{actions: @actions}}) == %{}
    assert ActionAnnotations.declared_actions(%{}) == %{}
  end
end
