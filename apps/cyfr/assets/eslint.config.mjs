// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
// eslint's recommended rules over the console's JavaScript and the SDK's
// source (js/), which run in a browser page, a frame or a worker. The unit
// tests, the vendored libraries and the built bundles under priv/static are
// not linted. Run from this directory: npx eslint .
import js from "@eslint/js"
import globals from "globals"

export default [
  {ignores: ["node_modules/", "vendor/", "test/", "css/"]},
  {
    files: ["js/**/*.js"],
    ...js.configs.recommended,
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
      globals: {...globals.browser, ...globals.worker}
    },
    rules: {
      ...js.configs.recommended.rules,
      // A leading underscore is this code's mark for a binding it means
      // not to use, a caught error most often.
      "no-unused-vars": [
        "error",
        {
          argsIgnorePattern: "^_",
          varsIgnorePattern: "^_",
          caughtErrorsIgnorePattern: "^_",
          destructuredArrayIgnorePattern: "^_"
        }
      ]
    }
  },
  {
    // CONTROL matches the C0 and C1 control characters on purpose: a value
    // holding one is refused.
    files: ["js/toolkit/wire.js"],
    rules: {"no-control-regex": "off"}
  },
  {
    // Three initial values every path overwrites (`let x = null` before a
    // try whose body and catch both assign x): device_key.js:425 and
    // worker.js:212 and :344. Removing them changes shipped sources, and the
    // toolkit's tracked bundle with them; this entry goes with that change.
    files: ["js/system_layer/device_key.js", "js/toolkit/worker.js"],
    rules: {"no-useless-assignment": "off"}
  }
]
