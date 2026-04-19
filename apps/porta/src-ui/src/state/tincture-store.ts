import { create } from "zustand";
import type { McpClient } from "../api/mcp-client";
import type { TinctureEntry } from "../api/types";
import * as cyfrMcp from "../api/cyfr-mcp";

/** Image extensions accepted by the CYFR tincture asset route. Mirrors the
 *  server-side `@allowed_extensions` whitelist in `tincture_helpers.ex`. */
const IMAGE_EXTENSIONS = new Set([".png", ".jpg", ".jpeg", ".svg", ".gif"]);

/** Max preview images shown per tincture in the picker UI. */
const MAX_PREVIEWS = 6;

/** Title-case a tincture slug for display. "voxel-destroyer" → "Voxel Destroyer". */
function titleFromName(name: string): string {
  const parts = name
    .split(/[-_\s]+/)
    .filter(Boolean)
    .map((w) => w[0]!.toUpperCase() + w.slice(1));
  return parts.length > 0 ? parts.join(" ") : name;
}

/** Build a tincture:// URL for an asset relative to a tincture's directory.
 *  Returns null if the path looks unsafe or has a non-image extension —
 *  the server will run its own validators, this is just a fast client-side
 *  reject for obviously bad inputs. */
function buildAssetUrl(
  publisher: string,
  name: string,
  relPath: string,
  sessionId: string,
): string | null {
  if (
    typeof relPath !== "string" ||
    relPath.length === 0 ||
    relPath.startsWith("/") ||
    relPath.includes("..") ||
    relPath.includes("\0") ||
    relPath.includes("\\")
  ) {
    return null;
  }

  const dot = relPath.lastIndexOf(".");
  if (dot < 0) return null;
  const ext = relPath.slice(dot).toLowerCase();
  if (!IMAGE_EXTENSIONS.has(ext)) return null;

  const encodedPath = relPath
    .split("/")
    .map((seg) => encodeURIComponent(seg))
    .join("/");
  const sessionQuery = sessionId
    ? `?_session=${encodeURIComponent(sessionId)}`
    : "";

  return `tincture://localhost/t/${encodeURIComponent(
    publisher,
  )}/${encodeURIComponent(name)}/${encodedPath}${sessionQuery}`;
}

interface TinctureState {
  tinctures: TinctureEntry[];
  loading: boolean;
  /** Name of the tincture currently shown full-screen, or null when the picker is visible. */
  viewing: string | null;
  /** Carousel cursor in the picker — index into `tinctures`. */
  focusedIndex: number;
  /** Which preview index is showing for the focused tincture (0-based). Reset to 0 when focusedIndex changes. */
  currentPreviewIndex: number;
  /** Warm iframe cache: tinctures that have been launched and should keep state. */
  openedTinctures: string[];

  loadTinctures: (client: McpClient) => Promise<void>;
  toggleVisibility: (client: McpClient, publisher: string, name: string) => Promise<void>;
  selectTincture: (name: string) => void;
  closeTincture: (name: string) => void;
  closeViewer: () => void;
  setFocusedIndex: (index: number) => void;
  nextPreview: () => void;
  previousPreview: () => void;
  refreshTinctures: (client: McpClient) => Promise<void>;
}

export const useTinctureStore = create<TinctureState>((set, get) => ({
  tinctures: [],
  loading: false,
  viewing: null,
  focusedIndex: 0,
  currentPreviewIndex: 0,
  openedTinctures: [],

  loadTinctures: async (client) => {
    set({ loading: true });
    try {
      const sessionId = client.sessionId ?? "";

      const listResult = await client.callTool("component", {
        action: "list",
        type: "tincture",
        limit: 1000,
      });
      const components = (listResult.components as Record<string, unknown>[]) ?? [];

      const tinctures: TinctureEntry[] = [];
      for (const c of components) {
        const publisher = (c.publisher as string) ?? "local";
        const name = (c.name as string) ?? "";
        if (!name) continue;

        const title = titleFromName(name);
        let description: string | null = null;
        let iconHint: string | null = null;
        let iconUrl: string | null = null;
        let previews: string[] = [];
        let tagline: string | null = null;
        try {
          // The MCP `component list` action returns the manifest as a nested
          // JSON object (not a string). Older code paths may still serialize
          // it as a string, so handle both shapes defensively.
          const rawManifest = c.manifest;
          let manifest: Record<string, unknown> | null = null;
          if (typeof rawManifest === "string" && rawManifest.length > 0) {
            manifest = JSON.parse(rawManifest) as Record<string, unknown>;
          } else if (rawManifest && typeof rawManifest === "object") {
            manifest = rawManifest as Record<string, unknown>;
          }
          if (manifest) {
            const rawDesc = manifest.description;
            if (typeof rawDesc === "string" && rawDesc.trim().length > 0) {
              description = rawDesc.trim();
            }
            const tinctureMeta = manifest.tincture as Record<string, unknown> | undefined;

            const icon = tinctureMeta?.icon;
            if (typeof icon === "string" && icon.length > 0) {
              iconHint = icon;
            }

            const tag = tinctureMeta?.tagline;
            if (typeof tag === "string" && tag.length > 0) {
              tagline = tag;
            }

            const media = tinctureMeta?.media as Record<string, unknown> | undefined;
            if (media) {
              const mediaIcon = media.icon;
              if (typeof mediaIcon === "string") {
                iconUrl = buildAssetUrl(publisher, name, mediaIcon, sessionId);
              }

              const mediaPreviews = media.previews;
              if (Array.isArray(mediaPreviews)) {
                previews = mediaPreviews
                  .slice(0, MAX_PREVIEWS)
                  .map((p) =>
                    typeof p === "string"
                      ? buildAssetUrl(publisher, name, p, sessionId)
                      : null,
                  )
                  .filter((u): u is string => u !== null);
              }
            }
          }
        } catch {
          const raw = c.description;
          if (typeof raw === "string" && raw.trim().length > 0) {
            description = raw.trim();
          }
        }

        let isPublic = false;
        try {
          const visResult = await client.callTool("tincture_visibility", {
            action: "get",
            publisher,
            name,
          });
          isPublic = (visResult.public as boolean) ?? false;
        } catch {
          // Default to private
        }

        tinctures.push({
          name,
          publisher,
          title,
          iconHint,
          iconUrl,
          previews,
          tagline,
          description,
          public: isPublic,
          component_ref: (c.component_ref as string) ?? `tincture:${publisher}.${name}`,
        });
      }

      // Clamp focusedIndex if the list shrank.
      const currentFocused = get().focusedIndex;
      const clampedFocused = tinctures.length === 0
        ? 0
        : Math.min(currentFocused, tinctures.length - 1);
      set({ tinctures, loading: false, focusedIndex: clampedFocused });
    } catch {
      set({ loading: false });
    }
  },

  toggleVisibility: async (client, publisher, name) => {
    const tincture = get().tinctures.find((t) => t.publisher === publisher && t.name === name);
    if (!tincture) return;

    const newPublic = !tincture.public;

    set({
      tinctures: get().tinctures.map((t) =>
        t.publisher === publisher && t.name === name
          ? { ...t, public: newPublic }
          : t
      ),
    });

    try {
      await client.callTool("tincture_visibility", {
        action: "set",
        publisher,
        name,
        public: newPublic,
      });
    } catch {
      set({
        tinctures: get().tinctures.map((t) =>
          t.publisher === publisher && t.name === name
            ? { ...t, public: !newPublic }
            : t
        ),
      });
    }
  },

  selectTincture: (name) => {
    const opened = get().openedTinctures;
    set({
      viewing: name,
      openedTinctures: opened.includes(name) ? opened : [...opened, name],
    });
  },

  closeTincture: (name) => {
    const opened = get().openedTinctures.filter((n) => n !== name);
    const viewing = get().viewing === name ? null : get().viewing;
    set({ openedTinctures: opened, viewing });
  },

  closeViewer: () => {
    set({ viewing: null });
  },

  setFocusedIndex: (index) => {
    const len = get().tinctures.length;
    if (len === 0) {
      set({ focusedIndex: 0, currentPreviewIndex: 0 });
      return;
    }
    const clamped = Math.max(0, Math.min(index, len - 1));
    // Reset preview cursor whenever the focused tincture changes.
    set({ focusedIndex: clamped, currentPreviewIndex: 0 });
  },

  nextPreview: () => {
    const { tinctures, focusedIndex, currentPreviewIndex } = get();
    const focused = tinctures[focusedIndex];
    if (!focused || focused.previews.length <= 1) return;
    set({ currentPreviewIndex: (currentPreviewIndex + 1) % focused.previews.length });
  },

  previousPreview: () => {
    const { tinctures, focusedIndex, currentPreviewIndex } = get();
    const focused = tinctures[focusedIndex];
    if (!focused || focused.previews.length <= 1) return;
    const len = focused.previews.length;
    set({ currentPreviewIndex: (currentPreviewIndex - 1 + len) % len });
  },

  refreshTinctures: async (client) => {
    try {
      await cyfrMcp.registerComponents(client);
    } catch {
      // Non-fatal
    }
    await get().loadTinctures(client);
  },
}));
