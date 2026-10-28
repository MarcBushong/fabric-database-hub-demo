// @vitest-environment node
// package.json overrides zod (GHSA-mrhx-c7xc-m3w5) with a release outside the range that the pinned Rayfin packages
// declare (@microsoft/rayfin-tools-common 1.36.2 wants ~4.3.6), so this test runs Rayfin's own zod code with the
// override: the template manifest validation behind `rayfin init`, the only place Rayfin uses zod (the app's browser
// bundle has none). The expected results are what the same calls returned with zod 4.3.6, but for the one difference
// noted below. Remove this test with the override once a Rayfin release depends on a fixed zod (Phase 27).
import { parseManifestFromString, validateManifest } from "@microsoft/rayfin-tools-common/_internal/templates";
import { describe, expect, it } from "vitest";

describe("the zod override with the pinned Rayfin packages", () => {
    it("accepts valid template manifests, groups included", () => {
        const manifest = {
            apiVersion: "v1",
            metadata: { name: "dbhub", tags: ["demo"] },
            entries: [
                { name: "dataapp", path: "dataapp" },
                { group: { name: "more", displayName: "More", entries: [{ path: "templates/other" }] } },
            ],
        };
        expect(validateManifest(manifest)).toEqual([]);
        expect(parseManifestFromString("apiVersion: v1\nmetadata:\n  name: dbhub\nentries:\n  - path: dataapp\n")).toEqual({
            apiVersion: "v1",
            metadata: { name: "dbhub" },
            entries: [{ path: "dataapp" }],
        });
    });

    it("rejects invalid manifests with Rayfin's messages, at the same paths as with zod 4.3.6", () => {
        const errors = validateManifest({
            apiVersion: "v2",
            metadata: { name: "" },
            entries: [{ path: "../outside" }, { path: "dataapp", group: { name: "g" } }],
        });
        expect(errors.slice(0, 3)).toEqual([
            "apiVersion: apiVersion must be 'v1'",
            "metadata.name: metadata.name is required",
            "entries.0.path: path must be a relative path without '..' segments",
        ]);
        // The one difference from zod 4.3.6, which reported "entries.1: Invalid input" here: zod 4.6.7 names the issue of
        // the union branch that comes closest. The entry is rejected either way.
        expect(errors.slice(3)).toEqual(['entries.1: Unrecognized key: "group"']);
        expect(
            validateManifest({ apiVersion: "v1", metadata: { name: "x" }, entries: [{ path: "a", group: { name: "g", displayName: "G", entries: [{ path: "b" }] } }] }),
        ).toEqual(["entries.0: Invalid input"]);
        expect(validateManifest({ apiVersion: "v1", metadata: { name: "x" }, entries: [{ path: "C:\\temp" }] })).toEqual([
            "entries.0.path: path must be a relative path without '..' segments",
        ]);
        expect(
            validateManifest({ apiVersion: "v1", metadata: { name: "x" }, entries: [{ group: { name: "g", displayName: "G", entries: [] } }] }),
        ).toEqual(["entries.0.group.entries: group.entries must not be empty"]);
        expect(validateManifest({ apiVersion: "v1", metadata: { name: "x" }, entries: [] })).toEqual([
            "entries: entries must contain at least one entry",
        ]);
        expect(validateManifest({ apiVersion: "v1", metadata: { name: 5, tags: "t" }, entries: "nope" })).toEqual([
            "metadata.name: Invalid input: expected string, received number",
            "metadata.tags: Invalid input: expected array, received string",
            "entries: Invalid input: expected array, received string",
        ]);
    });

    it("runs Rayfin's checks after zod's, and throws for an invalid manifest", () => {
        expect(validateManifest({ apiVersion: "v1", metadata: { name: "x" }, entries: [{ path: "a" }, { path: "a" }, { name: "a", path: "b" }] })).toEqual([
            "entries[1].path 'a' is a duplicate",
            "entries[2].name 'a' collides with an entry path",
        ]);
        expect(() => parseManifestFromString("apiVersion: v1\nmetadata: {}\nentries: []\n")).toThrow(
            "Invalid template manifest:\n  - metadata.name: Invalid input: expected string, received undefined\n  - entries: entries must contain at least one entry",
        );
    });
});
