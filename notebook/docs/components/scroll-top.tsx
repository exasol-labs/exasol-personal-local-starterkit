'use client';
/**
 * A new page opens at its top. The framework keeps the scroll position when
 * the next page's first element is already on screen, which it always is
 * under the sticky top bar: a reader at the foot of one page landed at the
 * foot of the next. Going back or forward still returns to where the reader
 * was, and a link to a heading (#anchor) still goes to that heading.
 */
import { usePathname } from 'next/navigation';
import { useEffect, useRef } from 'react';

export function ScrollTop() {
  const pathname = usePathname();
  const history = useRef(false);     // this change came from Back / Forward
  const first = useRef(true);

  useEffect(() => {
    const onPop = () => {
      history.current = true;
    };
    window.addEventListener('popstate', onPop);
    return () => window.removeEventListener('popstate', onPop);
  }, []);

  useEffect(() => {
    if (first.current) {
      first.current = false;         // the page as it was opened: the browser places it
      return;
    }
    if (history.current) {
      history.current = false;
      return;
    }
    if (window.location.hash) return;
    window.scrollTo({ top: 0, left: 0, behavior: 'instant' });
  }, [pathname]);

  return null;
}
