import eslint from "@eslint/js";
import { defineConfig } from "eslint/config";
import reactHooks from "eslint-plugin-react-hooks";
import reactRefresh from "eslint-plugin-react-refresh";
import globals from "globals";
import tseslint from "typescript-eslint";

export default defineConfig(
    { ignores: ["dist", "node_modules", "rayfin/.temp"] },
    {
        extends: [eslint.configs.recommended],
        files: ["scripts/**/*.mjs"],
        languageOptions: { globals: globals.node },
    },
    {
        extends: [eslint.configs.recommended, ...tseslint.configs.recommended],
        files: ["scripts/**/*.ts", "*.config.ts"],
        languageOptions: { globals: globals.node },
    },
    {
        extends: [eslint.configs.recommended, ...tseslint.configs.recommended],
        files: ["src/**/*.{ts,tsx}", "rayfin/**/*.ts"],
        languageOptions: { globals: globals.browser },
        plugins: { "react-hooks": reactHooks, "react-refresh": reactRefresh },
        rules: {
            ...reactHooks.configs.recommended.rules,
            "react-refresh/only-export-components": ["warn", { allowConstantExport: true }],
        },
    },
    {
        files: ["src/test/**/*.{ts,tsx}", "src/**/*.test.{ts,tsx}"],
        rules: { "react-refresh/only-export-components": "off" },
    },
);
