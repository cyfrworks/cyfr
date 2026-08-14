# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.NormalizeTinctureDigests do
  @moduledoc """
  Give tincture rows the `sha256:`-prefixed digest spelling every other
  component row carries.

  TinctureValidator used to store bare lowercase hex while Cyfr.Digest
  producers (wasm validation, OCI blobs) store `sha256:<hex>`, so
  `components.digest` held two formats depending on `component_type` and a
  digest lookup could not compare rows without knowing the type. The
  validator now routes through Cyfr.Digest; this backfills the stored rows
  to the one spelling.
  """
  use Ecto.Migration

  def up do
    execute """
    UPDATE components
    SET digest = 'sha256:' || digest
    WHERE component_type = 'tincture'
      AND digest IS NOT NULL
      AND digest != ''
      AND digest NOT LIKE 'sha256:%'
    """
  end

  def down do
    execute """
    UPDATE components
    SET digest = REPLACE(digest, 'sha256:', '')
    WHERE component_type = 'tincture'
    """
  end
end
