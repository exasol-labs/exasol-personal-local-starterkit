/**
 * The Data Scientist workflow as pictures: the eight stages as clickable cards (StageMap), the way between them on
 * every stage page (StageNav), and flowcharts drawn from plain data (Flow). Plain markup and the site's own colour
 * tokens, so they follow light and dark mode and need no script at run time.
 */
import Link from 'next/link';
import type { ReactNode } from 'react';
import {
  Activity,
  ArrowDown,
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

const TONES: Record<NonNullable<FlowStep['tone']>, string> = {
  you: 'border-fd-primary',
  kit: 'border-sky-500/70',
  db: 'border-amber-500/70',
  ai: 'border-fuchsia-500/70',
};

function FlowBox({ step }: { step: FlowStep }) {
  const body = (
    <>
      <span className="font-semibold text-fd-foreground">{step.title}</span>
      {step.text && <span className="text-sm text-fd-muted-foreground">{step.text}</span>}
      {step.code && <code className="mt-1 w-fit max-w-full break-all rounded bg-fd-muted px-1.5 py-0.5 text-xs">{step.code}</code>}
    </>
  );
  const cls = `flex min-w-0 flex-1 flex-col gap-1 rounded-lg border-2 bg-fd-card p-3 ${TONES[step.tone ?? 'kit']}`;
  return step.href ? (
    <Link href={step.href} className={`${cls} no-underline hover:bg-fd-accent/40`}>
      {body}
    </Link>
  ) : (
    <div className={cls}>{body}</div>
  );
}

/**
 * A flowchart: boxes joined by arrows, left to right on a wide screen and top to bottom on a phone (or always top
 * to bottom with vertical). A box's tone says who acts: you (green), the kit (blue), the database (amber), an AI
 * model (pink); the legend under the chart names the tones it uses.
 */
export function Flow({ steps, vertical, caption }: { steps: FlowStep[]; vertical?: boolean; caption?: ReactNode }) {
  const used = Array.from(new Set(steps.map((s) => s.tone ?? 'kit')));
  const names = { you: 'You', kit: 'The kit', db: 'The database', ai: 'An AI model' } as const;
  const dir = vertical ? 'flex-col' : 'flex-col md:flex-row';
  return (
    <figure className="not-prose my-6">
      <div className={`flex ${dir} items-stretch gap-2`}>
        {steps.map((step, i) => (
          <div key={i} className={`flex ${dir} flex-1 items-stretch gap-2 ${vertical ? '' : 'md:items-center'}`}>
            <FlowBox step={step} />
            {i < steps.length - 1 && (
              <span className="flex shrink-0 justify-center self-center text-fd-muted-foreground" aria-hidden>
                <ArrowDown className={`size-5 ${vertical ? '' : 'md:hidden'}`} />
                {!vertical && <ArrowRight className="hidden size-5 md:block" />}
              </span>
            )}
          </div>
        ))}
      </div>
      <figcaption className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-fd-muted-foreground">
        {caption && <span>{caption}</span>}
        {used.map((tone) => (
          <span key={tone} className="flex items-center gap-1">
            <span className={`inline-block size-3 rounded-sm border-2 ${TONES[tone]}`} /> {names[tone]}
          </span>
        ))}
      </figcaption>
    </figure>
  );
}
