// Root shared ESLint flat config.
//
// apps/api and packages/db import this directly (see their own
// eslint.config.mjs). apps/web keeps eslint-config-next's flat config (Next.js
// needs its own plugin set) but also pulls in eslint-config-prettier from here
// so ESLint never fights Prettier's formatting — that's the "shared ... via
// extends/config references from each app" wiring for this repo.
import js from "@eslint/js";
import tseslint from "typescript-eslint";
import eslintConfigPrettier from "eslint-config-prettier";

/** @type {import("eslint").Linter.Config[]} */
const baseConfig = [
  {
    ignores: [
      "**/node_modules/**",
      "**/dist/**",
      "**/.next/**",
      "**/out/**",
      "**/drizzle/**",
    ],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  eslintConfigPrettier,
];

export default baseConfig;
