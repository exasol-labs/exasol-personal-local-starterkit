'use client';
/**
 * A Mermaid diagram, drawn in the browser from its text. Mermaid is bundled with the site, so a diagram needs no
 * internet. It is drawn again when the reader switches between light and dark, in that theme's colours.
 */
import { useTheme } from 'next-themes';
import { useEffect, useId, useRef, useState } from 'react';

const PALETTE = {
  light: { ground: '#ffffff', text: '#18181b', muted: '#52525b', line: '#a1a1aa', you: '#3f8f22', kit: '#0369a1', db: '#b45309', ai: '#a21caf',
           youFill: '#f0f9eb', kitFill: '#eff6fb', dbFill: '#fdf6ec', aiFill: '#fbf0fc' },
  dark: { ground: '#0a0a0b', text: '#f4f4f5', muted: '#a1a1aa', line: '#71717a', you: '#7ddc57', kit: '#38bdf8', db: '#f59e0b', ai: '#e879f9',
          youFill: '#15210f', kitFill: '#0c1c26', dbFill: '#241a08', aiFill: '#23102a' },
} as const;

/** The class definitions every chart of the site shares: one look per actor (see workflow.tsx). */
function classes(mode: 'light' | 'dark'): string {
  const p = PALETTE[mode];
  return (['you', 'kit', 'db', 'ai'] as const)
    .map((tone) => `classDef ${tone} fill:${p[`${tone}Fill`]},stroke:${p[tone]},stroke-width:1.5px,color:${p.text};`)
    .join('\n');
}

const SMALL = new Set(['the', 'a', 'an', 'and', 'or', 'of', 'to', 'in', 'on', 'is', 'it', 'its', 'for', 'with', 'you', 'your',
                       'from', 'by', 'at', 'as', 'one', 'that', 'this', 'what', 'how', 'are', 'be', 'kit']);
const words = (text: string) =>
  text.toLowerCase().replace(/[^a-z0-9 ]+/g, ' ').split(/\s+/).filter((w) => w.length > 2 && !SMALL.has(w))
    .map((w) => w.replace(/(ing|ed|es|s)$/, ''));

/**
 * Every node of a chart goes somewhere: a node without a link of its own is tied to the section of this page that
 * explains it - the heading sharing the most words with the node's title, then with its text - and a click
 * scrolls there. A node no heading matches stays as it is.
 */
function linkToSections(root: HTMLElement): void {
  type Target = { set: Set<string>; label: string; go: () => void };
  const scope = root.closest('article') ?? document.querySelector('main') ?? document.body;
  const sections: Target[] = Array.from(scope.querySelectorAll<HTMLElement>('h2[id], h3[id]')).map((el) => ({
    set: new Set(words(el.textContent ?? '')),
    label: el.textContent ?? '',
    go: () => {
      el.scrollIntoView({ behavior: 'smooth', block: 'start' });
      history.replaceState(null, '', `#${el.id}`);
    },
  }));
  // the page's cards (a stage's subpages): a node about "checks" opens the Data checks page
  const cards: Target[] = Array.from(scope.querySelectorAll<HTMLAnchorElement>('a[data-card]'))
    .filter((el) => !root.contains(el))
    .map((el) => {
      const label = (el.querySelector('h3, h4, p')?.textContent ?? el.textContent ?? '').trim();
      return { set: new Set(words(label)), label, go: () => el.click() };
    });
  // with nothing better, a node leads to the section that follows its chart: charts stand before their explanation
  const figure = root.closest('figure') ?? root;
  const after = Array.from(scope.querySelectorAll<HTMLElement>('h2[id], h3[id]')).find(
    (el) => figure.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING,
  );
  const fallback = after ? sections.find((t) => t.label === (after.textContent ?? '')) : sections[sections.length - 1];
  root.querySelectorAll<SVGGElement>('g.node').forEach((node) => {
    if (node.closest('a')) return;                                   // it links to another page already
    const title = words(node.querySelector('b')?.textContent ?? '');
    const rest = words(node.textContent ?? '');
    let best: Target | undefined;
    let top = 0;
    for (const target of [...cards, ...sections]) {
      const score = title.filter((w) => target.set.has(w)).length * 3 + rest.filter((w) => target.set.has(w)).length;
      if (score > top) {
        top = score;
        best = target;
      }
    }
    const target = top >= 3 ? best : fallback;                       // one word of the title, or three of the text
    if (!target) return;
    node.style.cursor = 'pointer';
    node.setAttribute('role', 'link');
    node.setAttribute('tabindex', '0');
    const tip = document.createElementNS('http://www.w3.org/2000/svg', 'title');
    tip.textContent = `Go to: ${target.label}`;
    node.prepend(tip);
    node.addEventListener('click', target.go);
    node.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        target.go();
      }
    });
  });
}

export function Mermaid({ chart }: { chart: string }) {
  const id = useId().replace(/[^a-zA-Z0-9]/g, '');
  const box = useRef<HTMLDivElement>(null);
  const { resolvedTheme } = useTheme();
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let cancelled = false;
    const mode = resolvedTheme === 'dark' ? 'dark' : 'light';
    const p = PALETTE[mode];
    (async () => {
      const mermaid = (await import('mermaid')).default;
      mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'loose',                 // our own pages' text: labels carry markup and links
        theme: 'base',
        fontFamily: 'inherit',
        themeVariables: { background: p.ground, primaryColor: p.kitFill, primaryBorderColor: p.kit, primaryTextColor: p.text,
                          lineColor: p.line, textColor: p.text, fontSize: '14px', edgeLabelBackground: p.ground },
        flowchart: { htmlLabels: true, curve: 'basis', padding: 14, nodeSpacing: 36, rankSpacing: 46, useMaxWidth: true },
      });
      try {
        const { svg, bindFunctions } = await mermaid.render(`m${id}${mode}`, `${chart}\n${classes(mode)}`);
        if (cancelled || !box.current) return;
        box.current.innerHTML = svg;
        bindFunctions?.(box.current);
        linkToSections(box.current);
        setFailed(false);
      } catch {
        if (!cancelled) setFailed(true);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [chart, id, resolvedTheme]);

  if (failed) return <pre className="text-xs">{chart}</pre>;      // the diagram's text, never an empty space
  return <div ref={box} className="flex min-h-24 justify-center overflow-x-auto [&_svg]:h-auto [&_svg]:max-w-full" />;
}
