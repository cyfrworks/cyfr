// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The production entry: the cyfr this package carries beside its code.

import path from "node:path"

import {startApp} from "./app.js"

const executable = process.platform === "win32" ? "cyfr.exe" : "cyfr"

startApp({cyfr: path.join(process.resourcesPath, executable), touchIdGroup: __CYFR_WEBAUTHN_GROUP__})
