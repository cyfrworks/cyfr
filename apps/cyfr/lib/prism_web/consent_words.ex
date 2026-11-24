# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ConsentWords do
  @moduledoc """
  The words a grant's preview rows (`Prima.ConsentPreview`) are read in:
  each kind's heading, a field's label and a frame's placement, as the
  consent sheet (`PrismWeb.ConsentSheetComponent`) draws them, and a
  row set in one line a kind for a page outside the sheet, such as what
  a shipped component's update adds to its grant.
  """

  @doc """
  Preview rows in one line a kind, as the sheet heads and names them
  ("Streams it listens to: system.changes"), in the sheet's order of
  kinds: what a page outside the sheet says of a grant, such as what an
  update adds to it.
  """
  @spec summary([map()]) :: [String.t()]
  def summary(rows) when is_list(rows) do
    kinds = Enum.map(Prima.ConsentPreview.kinds(), &Atom.to_string/1)

    rows
    |> Enum.group_by(& &1["kind"])
    |> Enum.sort_by(fn {kind, _rows} ->
      Enum.find_index(kinds, &(&1 == kind)) || length(kinds)
    end)
    |> Enum.map(fn {kind, rows} ->
      "#{kind_heading(kind)}: #{rows |> Enum.flat_map(&row_names/1) |> Enum.uniq() |> Enum.join(", ")}"
    end)
  end

  defp row_names(%{"kind" => kind, "values" => values}) when kind in ["egress", "storage"] do
    for {field, list} <- values,
        is_list(list),
        list != [],
        do: "#{field_label(kind, field)} #{Enum.join(list, ", ")}"
  end

  defp row_names(%{"kind" => "tools", "values" => %{"tools" => tools}}), do: tools
  defp row_names(%{"kind" => "system_actions", "values" => %{"actions" => actions}}), do: actions

  defp row_names(%{"kind" => "controls", "values" => %{"controls" => controls}}),
    do: Enum.map(controls, &"“#{&1["label"]}”")

  defp row_names(%{"kind" => "frame", "values" => values}) do
    List.wrap(values["capabilities"]) ++
      if(values["placement"], do: [placement_label(values["placement"])], else: [])
  end

  defp row_names(%{"values" => %{"name" => name}}) when is_binary(name), do: [name]
  defp row_names(_row), do: []

  @doc "A row kind's heading."
  @spec kind_heading(String.t()) :: String.t()
  def kind_heading("credential"), do: "Vault entries it receives"
  def kind_heading("egress"), do: "Network"
  def kind_heading("storage"), do: "Files"
  def kind_heading("tools"), do: "Tools"
  def kind_heading("tool_servers"), do: "Tool servers"
  def kind_heading("limits"), do: "Limits"
  def kind_heading("frame"), do: "Its frame"
  def kind_heading("streams"), do: "Streams it listens to"
  def kind_heading("system_actions"), do: "System actions it may call"
  def kind_heading("controls"), do: "Controls you can tap"
  def kind_heading(kind), do: kind

  @doc "A narrowable field's label."
  @spec field_label(String.t(), String.t()) :: String.t()
  def field_label("egress", "domains"), do: "Talks to"
  def field_label("egress", "methods"), do: "Methods"
  def field_label("egress", "schemes"), do: "Schemes"
  def field_label("egress", "private_ips"), do: "Private networks"
  def field_label("storage", "paths"), do: "Paths"
  def field_label("storage", "actions"), do: "Actions"

  # A canvas is read by what it reads: its streams are the sheet's rows.
  @doc "A frame's placement in words."
  @spec placement_label(term()) :: String.t()
  def placement_label("canvas"), do: "Can be a canvas, which reads the streams listed here"
  def placement_label(placement) when is_binary(placement), do: "Placed: #{placement}"
  def placement_label(_none), do: "Placed: where the shell places it"
end
