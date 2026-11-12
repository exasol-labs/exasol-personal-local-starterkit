/**
 * "Feedback or questions?" at the bottom right of every page: an e-mail to the Starter Kit team, with the page it
 * was sent from in the subject, so the answer can start from the same page. Plain markup: no script, no tracking.
 */
import { MessageCircleQuestion } from 'lucide-react';

export const FEEDBACK_ADDRESS = 'plg.connect@exasol.com';

export function Feedback() {
  const subject = encodeURIComponent('Starter Kit docs: feedback or a question');
  return (
    <a
      href={`mailto:${FEEDBACK_ADDRESS}?subject=${subject}`}
      title={`E-mail ${FEEDBACK_ADDRESS}`}
      className="fixed bottom-4 right-4 z-40 flex items-center gap-2 rounded-full border bg-fd-card px-4 py-2 text-sm font-medium text-fd-foreground no-underline shadow-lg transition-colors hover:border-fd-primary hover:text-fd-primary print:hidden"
    >
      <MessageCircleQuestion className="size-4 text-fd-primary" aria-hidden />
      Feedback or questions?
    </a>
  );
}
