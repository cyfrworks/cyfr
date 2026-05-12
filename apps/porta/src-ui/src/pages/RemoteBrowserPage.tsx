import { PageLayout } from "../components/common/PageLayout";

/**
 * Remote browser panel.
 *
 * `/browse` is reverse-proxied by the deployment's Caddy to the `neko`
 * service — Chromium running on the server, streamed over WebRTC. The same
 * Chromium is what AQUA's `chrome:*` MCP tools drive, so a person can watch
 * and take over here while an agent operates it.
 *
 * neko renders its own login form inside the iframe; credentials are the
 * `NEKO_*` password(s) configured on the server.
 */
export default function RemoteBrowserPage() {
  return (
    <PageLayout
      title="Remote Browser"
      subtitle="A Chromium running on your CYFR server, streamed here."
      bleed
      actions={
        <a
          href="/browse"
          target="_blank"
          rel="noopener noreferrer"
          className="rounded-lg px-3 py-1.5 text-xs text-accent-primary hover:text-accent-hover"
        >
          Open in new tab ↗
        </a>
      }
    >
      <div className="relative h-full w-full">
        <iframe
          src="/browse"
          title="Remote Browser"
          className="absolute inset-0 h-full w-full border-0"
          allow="clipboard-read; clipboard-write; microphone; camera; fullscreen; autoplay"
        />
      </div>
    </PageLayout>
  );
}
