'use client';
import SearchDialog from '@/components/search';
import { ScrollTop } from '@/components/scroll-top';
import { Feedback } from '@/components/feedback';
import { RootProvider } from 'fumadocs-ui/provider/next';
import { type ReactNode } from 'react';

export function Provider({ children }: { children: ReactNode }) {
  return (
    <RootProvider search={{ SearchDialog }}>
      <ScrollTop />
      {children}
      <Feedback />
    </RootProvider>
  );
}
