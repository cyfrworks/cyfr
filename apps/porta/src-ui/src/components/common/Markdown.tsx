import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { useEffect, useRef } from "react";
import hljs from "highlight.js/lib/core";
import javascript from "highlight.js/lib/languages/javascript";
import typescript from "highlight.js/lib/languages/typescript";
import python from "highlight.js/lib/languages/python";
import bash from "highlight.js/lib/languages/bash";
import json from "highlight.js/lib/languages/json";
import elixir from "highlight.js/lib/languages/elixir";
import rust from "highlight.js/lib/languages/rust";
import go from "highlight.js/lib/languages/go";
import sql from "highlight.js/lib/languages/sql";
import yaml from "highlight.js/lib/languages/yaml";
import xml from "highlight.js/lib/languages/xml";
import css from "highlight.js/lib/languages/css";

hljs.registerLanguage("javascript", javascript);
hljs.registerLanguage("js", javascript);
hljs.registerLanguage("typescript", typescript);
hljs.registerLanguage("ts", typescript);
hljs.registerLanguage("python", python);
hljs.registerLanguage("bash", bash);
hljs.registerLanguage("sh", bash);
hljs.registerLanguage("json", json);
hljs.registerLanguage("elixir", elixir);
hljs.registerLanguage("rust", rust);
hljs.registerLanguage("go", go);
hljs.registerLanguage("sql", sql);
hljs.registerLanguage("yaml", yaml);
hljs.registerLanguage("xml", xml);
hljs.registerLanguage("html", xml);
hljs.registerLanguage("css", css);

export function Markdown({ content }: { content: string }) {
  return (
    <div className="prose prose-invert max-w-none text-sm leading-relaxed">
    <ReactMarkdown
      remarkPlugins={[remarkGfm]}
      components={{
        code: CodeBlock,
        pre: ({ children }) => <>{children}</>,
        a: ({ href, children }) => (
          <a
            href={href}
            target="_blank"
            rel="noopener noreferrer"
            className="text-accent-primary hover:text-accent-hover"
          >
            {children}
          </a>
        ),
        table: ({ children }) => (
          <div className="overflow-x-auto">
            <table className="min-w-full border-collapse border border-border-default text-xs">
              {children}
            </table>
          </div>
        ),
        th: ({ children }) => (
          <th className="border border-border-default bg-surface-overlay px-3 py-1.5 text-left text-text-secondary">
            {children}
          </th>
        ),
        td: ({ children }) => (
          <td className="border border-border-default px-3 py-1.5">
            {children}
          </td>
        ),
      }}
    >
      {content}
    </ReactMarkdown>
    </div>
  );
}

function CodeBlock({
  className,
  children,
}: {
  className?: string;
  children?: React.ReactNode;
}) {
  const ref = useRef<HTMLElement>(null);
  const lang = className?.replace("language-", "");
  const code = String(children).replace(/\n$/, "");

  // Inline code (no language)
  if (!lang && !code.includes("\n")) {
    return (
      <code className="rounded bg-surface-overlay px-1.5 py-0.5 text-xs font-mono text-accent-primary">
        {code}
      </code>
    );
  }

  useEffect(() => {
    if (ref.current && lang && hljs.getLanguage(lang)) {
      ref.current.innerHTML = hljs.highlight(code, { language: lang }).value;
    }
  }, [code, lang]);

  return (
    <div className="group relative my-3 overflow-hidden rounded-lg border border-border-default">
      {lang && (
        <div className="flex items-center justify-between border-b border-border-default bg-surface-overlay px-3 py-1">
          <span className="text-xs text-text-muted">{lang}</span>
          <CopyButton text={code} />
        </div>
      )}
      <pre className="overflow-x-auto bg-surface-raised p-3">
        <code ref={ref} className="text-xs font-mono text-text-primary">
          {code}
        </code>
      </pre>
    </div>
  );
}

function CopyButton({ text }: { text: string }) {
  const handleCopy = async () => {
    await navigator.clipboard.writeText(text);
  };

  return (
    <button
      onClick={handleCopy}
      className="text-xs text-text-muted opacity-0 transition-opacity hover:text-text-secondary group-hover:opacity-100"
    >
      Copy
    </button>
  );
}
