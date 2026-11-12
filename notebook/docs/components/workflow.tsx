/**
 * The Data Scientist workflow as pictures: the eight stages as clickable cards (StageMap), the way between them on
 * every stage page (StageNav), and flowcharts drawn from plain data (Flow). Plain markup and the site's own colour
 * tokens, so they follow light and dark mode and need no script at run time.
 */
import Link from 'next/link';
import type { ReactNode } from 'react';
import { Mermaid } from './mermaid';
import {
  Activity,
  ArrowLeft,
  ArrowRight,
  Brain,
  ClipboardCheck,
  Database,
  Presentation,
  RefreshCw,
  Search,
  ServerCog,
  Wand2,
} from 'lucide-react';

const BASE = '/data-scientist';

export const STAGES = [
  { n: 1, slug: 'set-up', title: 'Set up Exasol', sub: 'Database, notebooks, AI', icon: ServerCog },
  { n: 2, slug: 'get-the-data', title: 'Get the data', sub: 'Samples, files, sources', icon: Database },
  { n: 3, slug: 'explore', title: 'Explore and understand', sub: 'Meaning, patterns, semantics', icon: Search },
  { n: 4, slug: 'prepare', title: 'Prepare', sub: 'Clean, join, features', icon: Wand2 },
  { n: 5, slug: 'model', title: 'Model', sub: 'Baseline first, then improve', icon: Brain },
  { n: 6, slug: 'evaluate', title: 'Evaluate', sub: 'Unseen data, right metric', icon: ClipboardCheck },
  { n: 7, slug: 'communicate', title: 'Communicate and deploy', sub: 'Story, dashboard, hand-off', icon: Presentation },
  { n: 8, slug: 'monitor', title: 'Monitor and iterate', sub: 'Change, feedback, rerun', icon: Activity },
] as const;

function StageCard({ stage, current }: { stage: (typeof STAGES)[number]; current?: number }) {
  const Icon = stage.icon;
  const on = current === stage.n;
  return (
    <Link
      href={`${BASE}/${stage.slug}`}
      aria-current={on ? 'page' : undefined}
      className={`group flex flex-col gap-2 rounded-xl border p-4 no-underline transition-colors hover:border-fd-primary hover:bg-fd-accent/40 ${
        on ? 'border-fd-primary bg-fd-accent/40' : 'bg-fd-card'
      }`}
    >
      <Icon className="size-6 text-fd-primary" aria-hidden />
      <span className="font-semibold text-fd-foreground leading-snug">{stage.title}</span>
      <span className="text-sm text-fd-muted-foreground">{stage.sub}</span>
    </Link>
  );
}

/** The eight stages as two rows of clickable cards, with the loop back underneath. */
export function StageMap({ current }: { current?: number }) {
  const rows: [string, typeof STAGES[number][]][] = [
    ['Get set up and understand the data', STAGES.slice(0, 4) as unknown as typeof STAGES[number][]],
    ['Build, prove, and deliver value', STAGES.slice(4) as unknown as typeof STAGES[number][]],
  ];
  return (
    <div className="not-prose my-6 flex flex-col gap-4">
      {rows.map(([label, stages]) => (
        <div key={label} className="flex flex-col gap-3">
          <div className="flex items-center gap-2 text-sm text-fd-muted-foreground">
            <ArrowRight className="size-4" aria-hidden /> {label}
          </div>
          <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
            {stages.map((stage) => (
              <StageCard key={stage.n} stage={stage} current={current} />
            ))}
          </div>
        </div>
      ))}
      <div className="flex items-center gap-2 text-sm text-fd-muted-foreground">
        <RefreshCw className="size-4" aria-hidden /> Every stage can send you back: a surprise in evaluation often means
        new features, new data, or a sharper question.
      </div>
    </div>
  );
}

/** The way on from a stage's page: back to the whole workflow, and the stage before and after it. */
export function StageNav({ n }: { n: number }) {
  const prev = STAGES.find((s) => s.n === n - 1);
  const next = STAGES.find((s) => s.n === n + 1);
  return (
    <nav aria-label="Workflow" className="not-prose mt-10 flex flex-wrap items-center justify-between gap-2 border-t pt-4 text-sm">
      <Link href={BASE} className="flex items-center gap-1 text-fd-muted-foreground no-underline hover:text-fd-primary">
        <ArrowLeft className="size-4" aria-hidden /> The whole workflow
      </Link>
      <span className="flex gap-4">
        {prev && (
          <Link href={`${BASE}/${prev.slug}`} className="no-underline text-fd-muted-foreground hover:text-fd-primary">
            ← {prev.title}
          </Link>
        )}
        {next && (
          <Link href={`${BASE}/${next.slug}`} className="no-underline text-fd-primary">
            {next.title} →
          </Link>
        )}
      </span>
    </nav>
  );
}

type FlowStep = { title: string; text?: string; code?: string; href?: string; tone?: 'you' | 'kit' | 'db' | 'ai' };

const NAMES = { you: 'You', kit: 'The kit', db: 'The database or a source', ai: 'An AI model or client' } as const;
// One shape per actor, so a chart reads without its legend: a person acts in a rounded box, the kit in a
// rectangle, data sits in a cylinder, an AI in a hexagon.
const SHAPES: Record<NonNullable<FlowStep['tone']>, [string, string]> = {
  you: ['([', '])'],
  kit: ['[', ']'],
  db: ['[(', ')]'],
  ai: ['{{', '}}'],
};
const SWATCH: Record<NonNullable<FlowStep['tone']>, string> = {
  you: 'border-[#3f8f22] dark:border-[#7ddc57] rounded-full',
  kit: 'border-[#0369a1] dark:border-[#38bdf8] rounded-none',
  db: 'border-[#b45309] dark:border-[#f59e0b] rounded-[40%]',
  ai: 'border-[#a21caf] dark:border-[#e879f9] rounded-sm rotate-45',
};

function safe(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '#quot;');
}

/** Break a line at words so a node stays compact: about `width` characters a line. */
function wrap(text: string, width: number): string {
  const lines: string[] = [];
  let line = '';
  for (const word of text.split(/\s+/)) {
    if (line && (line + ' ' + word).length > width) {
      lines.push(line);
      line = word;
    } else line = line ? `${line} ${word}` : word;
  }
  if (line) lines.push(line);
  return lines.map(safe).join('<br/>');
}

/** The Mermaid text of a flow: its steps as nodes in order, each shaped and coloured by who acts. */
export function flowChart(steps: FlowStep[], vertical?: boolean): string {
  const down = vertical || steps.length > 4;      // five side by side shrink the text too far to read
  const width = down ? 52 : 24;
  const lines = [`flowchart ${down ? 'TB' : 'LR'}`];
  steps.forEach((step, i) => {
    const tone = step.tone ?? 'kit';
    const [open, close] = SHAPES[tone];
    const label =
      `<b>${wrap(step.title, width)}</b>` +
      // no opacity, filter or transform in a label: WebKit (Safari) draws such content of an SVG label in the
      // wrong place, piling every node's text on the first node. A plain colour and size only.
      (step.text ? `<br/><span class='flow-sub'>${wrap(step.text, width + 4)}</span>` : '') +
      (step.code ? `<br/><span class='flow-code'>${wrap(step.code, width + 6)}</span>` : '');
    lines.push(`  s${i}${open}"${label}"${close}:::${tone}`);
    if (step.href) lines.push(`  click s${i} href "${step.href.startsWith('/') ? `/docs${step.href}` : step.href}"`);
  });
  for (let i = 0; i < steps.length - 1; i++) lines.push(`  s${i} --> s${i + 1}`);
  return lines.join('\n');
}

/**
 * A flowchart, drawn with Mermaid: the steps in order, joined by arrows, left to right (top to bottom with
 * `vertical`, or when there are more than four). A step's tone says who acts and sets its shape and colour; a step
 * with an href is a link. The legend names the actors the chart uses.
 */
export function Flow({ steps, vertical, caption }: { steps: FlowStep[]; vertical?: boolean; caption?: ReactNode }) {
  const used = Array.from(new Set(steps.map((s) => s.tone ?? 'kit')));
  return (
    <figure className="not-prose my-6 rounded-xl border bg-fd-card p-4">
      <Mermaid chart={flowChart(steps, vertical)} />
      <figcaption className="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1 border-t pt-3 text-xs text-fd-muted-foreground">
        {caption && <span className="font-medium text-fd-foreground">{caption}</span>}
        {used.map((tone) => (
          <span key={tone} className="flex items-center gap-1.5">
            <span className={`inline-block size-2.5 border-2 ${SWATCH[tone]}`} /> {NAMES[tone]}
          </span>
        ))}
      </figcaption>
    </figure>
  );
}
