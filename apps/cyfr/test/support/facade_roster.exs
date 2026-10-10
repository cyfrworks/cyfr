# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# The facade roster: for each foundation and domain root, the facade
# modules its Boundary `exports` must hold beyond the additions
# `Cyfr.BoundaryDeclarationsTest` rosters with their reasons. Generated
# from the tree at `a9dddcfb`; a change to a facade's exports is made here
# in the same change.
%{
  "Arca" => [
    "Arca.CanvasVersions",
    "Arca.FencedPublication",
    "Arca.FencedPublication.Change",
    "Arca.Files",
    "Arca.Layouts",
    "Arca.PlatformSettings",
    "Arca.Retention"
  ],
  "Sanctum" => [
    "Sanctum.Annotations",
    "Sanctum.Attach",
    "Sanctum.Auth.CyfrDoor",
    "Sanctum.Consent",
    "Sanctum.Decisions",
    "Sanctum.DeviceCerts",
    "Sanctum.Directory",
    "Sanctum.Gate",
    "Sanctum.InstanceEntries",
    "Sanctum.Pairing",
    "Sanctum.Passkeys",
    "Sanctum.Recovery",
    "Sanctum.RegistryCredentials",
    "Sanctum.RequestLog",
    "Sanctum.Resources",
    "Sanctum.RunningTasks",
    "Sanctum.TinctureAccess",
    "Sanctum.ToolGrants",
    "Sanctum.VirtualTools",
    "Sanctum.Visibility",
    "Sanctum.Webhook"
  ],
  "Compendium" => ["Compendium.Providers.Component"],
  "Opus" => [],
  "Aqua" => ["Aqua.Text"]
}
