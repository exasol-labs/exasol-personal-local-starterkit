import type { BaseLayoutProps } from 'fumadocs-ui/layouts/shared';
import { BrandLabel } from '@/components/brand-label';
import { appName } from './shared';

/** The full Exasol wordmark, as on the notebooks' cards: the letters follow the
 *  text color so it reads on both themes, the chevron keeps the brand green. */
function ExasolLogo() {
  return (
    <svg height="18" viewBox="0 0 110 26" role="img" aria-label="Exasol">
      <polygon points="0,0 0,25.5 16.1,25.5 16.1,21.5 4.7,21.5 4.7,14.7 13.4,14.7 13.4,10.7 4.7,10.7 4.7,4 15.5,4 15.5,0" fill="currentColor" />
      <path d="M54.7,22.9c-1.2,2-3.9,3-6.2,3c-5,0-9.3-3.7-9.3-9.5C39,11.4,42.9,7.2,48,7l0,0h0.5c2.2,0,4.9,0.9,6.2,2.9V7.4 h4v18.2h-4V22.9L54.7,22.9z M49,22c3,0.1,5.6-2.2,5.7-5.2c0-0.1,0-0.3,0-0.4c0-3-2.4-5.5-5.4-5.5H49c-3-0.1-5.5,2.2-5.6,5.2v0.3 c-0.1,3,2.3,5.5,5.4,5.6L49,22" fill="currentColor" />
      <path d="M64.4,20.1c1.4,1.3,3.2,2,5.1,2c1.3,0,2.4-0.6,2.4-1.7c0-2.7-9-2.4-9-8.3c0-3.4,3.1-5.4,7.1-5.4 s6.2,2.1,6.2,2.1l-1.7,3.4c-1.3-1-2.9-1.6-4.6-1.6c-1.2,0-2.4,0.5-2.4,1.7c0,2.6,9,2.3,9,8.2c0,3.1-2.7,5.5-7.1,5.5 c-2.7,0-5.2-0.9-7.2-2.7L64.4,20.1L64.4,20.1z" fill="currentColor" />
      <path d="M89.1,6.8c5.7,0,10.2,4,10.2,9.6S94.8,26,89.2,26C83.5,26,79,22,79,16.4S83.5,6.8,89.1,6.8 M89.2,22.1 c3,0,5.5-2.5,5.5-5.5l0,0v-0.2c0.2-3-2.2-5.6-5.2-5.7c-3-0.2-5.6,2.2-5.8,5.2v0.6c-0.1,3,2.2,5.6,5.2,5.7L89.2,22.1" fill="currentColor" />
      <path d="M102.8,0h4.6v19.2c0,2,0.7,2.5,1.9,2.5c0.4,0,0.7,0,0.7,0v4c-0.5,0.1-1,0.1-1.5,0.1c-2.5,0-5.7-0.6-5.7-5.9V0 L102.8,0z" fill="currentColor" />
      <polygon points="18.5,25.5 25.6,16.4 18.6,7.4 24,7.4 31,16.4 24,25.5" fill="#5FC33B" />
      <polygon points="29.3,11.9 32,15.4 38.2,7.4 32.8,7.3" fill="currentColor" />
      <polygon points="29.3,21 32,17.5 38.2,25.5 32.8,25.5" fill="currentColor" />
    </svg>
  );
}

export function baseOptions(): BaseLayoutProps {
  return {
    nav: {
      title: (
        <>
          <ExasolLogo />
          <span className="text-fd-muted-foreground text-[12px] font-semibold uppercase tracking-[0.08em] border-l ps-2.5 ms-1">
            <BrandLabel app={appName} />
          </span>
        </>
      ),
    },
    links: [],
    // The three-way segmented pill: light / dark / follow-the-system.
    themeSwitch: { mode: 'light-dark-system' },
  };
}
